/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.service;

import com.sap.ai.sdk.orchestration.OrchestrationAiModel;
import com.sap.ai.sdk.orchestration.OrchestrationModuleConfig;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatModel;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatOptions;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.MessageChatMemoryAdvisor;
import org.springframework.ai.chat.memory.InMemoryChatMemoryRepository;
import org.springframework.ai.chat.memory.MessageWindowChatMemory;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.mcp.SyncMcpToolCallbackProvider;
import org.springframework.ai.support.ToolCallbacks;
import org.springframework.stereotype.Service;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@Service
public class OrchestratorWorkersService {

    private static final Logger logger = LoggerFactory.getLogger(OrchestratorWorkersService.class);
    private static final String FINAL_MARKER = "[FINAL]";

    private static final String ORCHESTRATOR_PROMPT = """
        Today is %s.
        
        Analyze this query and break it down into parallel worker tasks.
        
        Query: {task}
        
        Available workers:
        - SAP Worker: Handles freight, warehouse, inventory queries using SAP APIs
        - Weather Worker: Handles weather forecasts and conditions (supports multi-day ranges in one call)
        - DateTime Worker: Handles date/time queries
        - AWS Worker: Handles AWS service questions, best practices, and architecture guidance using knowledge base tools
        
        RULES:
        1. If the query needs NO workers (greetings, general knowledge), prefix with [FINAL] and
           respond ONLY with the user-facing answer. No analysis, no JSON.
        2. Each worker should appear AT MOST ONCE. Do NOT split a single concern across multiple tasks.
        3. Only create multiple tasks when they are TRULY INDEPENDENT concerns (e.g., weather + SAP data).
        
        Return JSON:
        {
          "analysis": "brief explanation",
          "tasks": [
            {"id": "unique_short_id", "worker": "worker_name", "description": "what this worker should do"}
          ]
        }
        """;

    private static final String WORKER_PROMPT = """
        Execute this task: {task_description}
        
        Original query: {original_task}
        Worker type: {worker_type}
        
        Use available tools to complete the task and return results.
        """;

    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;
    private final OrchestrationChatOptions textOnlyOptions;
    private final MessageWindowChatMemory chatMemory;
    private final ExecutorService workerExecutor;

    public record Task(String id, String worker, String description) {}
    public record OrchestratorResponse(String analysis, List<Task> tasks) {}

    public OrchestratorWorkersService(
            DateTimeTools dateTimeTools,
            WeatherTools weatherTools,
            SyncMcpToolCallbackProvider mcpToolProvider,
            SAPOdataApiSelectorTool apiSelector,
            SAPApiExecutorTool apiExecutor) {

        var chatModel = new OrchestrationChatModel();
        var config = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        // Tool-enabled options for orchestrator + workers
        this.toolOptions = new OrchestrationChatOptions(config);
        var toolCallbacks = new ArrayList<>(List.of(ToolCallbacks.from(dateTimeTools, weatherTools, apiSelector, apiExecutor)));
        toolCallbacks.addAll(List.of(mcpToolProvider.getToolCallbacks()));
        this.toolOptions.setToolCallbacks(toolCallbacks);
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

        // Text-only options for synthesis — no tool schemas, faster
        this.textOnlyOptions = new OrchestrationChatOptions(config);

        var chatMemoryRepository = new InMemoryChatMemoryRepository();
        this.chatMemory = MessageWindowChatMemory.builder().chatMemoryRepository(chatMemoryRepository).build();
        this.workerExecutor = Executors.newFixedThreadPool(4);

        this.chatClient = ChatClient.builder(chatModel)
                .defaultAdvisors(MessageChatMemoryAdvisor.builder(chatMemory).build())
                .build();
    }

    public String execute(String userPrompt, String username) {
        long startTime = System.currentTimeMillis();
        logger.info("=== EXECUTION START === User: {}, Prompt: {}", username, userPrompt);

        try {
            // Step 1: Orchestrator breaks down task
            String orchestratorPrompt = String.format(ORCHESTRATOR_PROMPT, LocalDate.now())
                    .replace("{task}", userPrompt);
            String orchestratorConvId = username + "-orchestrator";

            long orchestratorStart = System.currentTimeMillis();
            String rawResponse = chatClient.prompt(new Prompt(orchestratorPrompt, toolOptions))
                    .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, orchestratorConvId))
                    .call().chatResponse().getResult().getOutput().getText();
            logger.info("Orchestrator completed in {}ms", System.currentTimeMillis() - orchestratorStart);

            // Short-circuit for non-worker queries
            if (rawResponse.startsWith(FINAL_MARKER)) {
                String response = rawResponse.substring(FINAL_MARKER.length()).trim();
                logger.info("Short-circuit: no workers needed. Total: {}ms", System.currentTimeMillis() - startTime);
                return response;
            }

            // Parse structured response
            OrchestratorResponse orchestratorResponse = chatClient.prompt(
                    new Prompt("Parse this JSON and return it as structured data: " + rawResponse, textOnlyOptions))
                    .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, orchestratorConvId + "-parse"))
                    .call().entity(OrchestratorResponse.class);

            logger.info("Tasks identified: {}. Analysis: {}", orchestratorResponse.tasks().size(), orchestratorResponse.analysis());

            // Step 2: Workers execute tasks in parallel (each with own conversation ID)
            long workersStart = System.currentTimeMillis();
            List<String> workerResponses;

            if (orchestratorResponse.tasks().size() == 1) {
                workerResponses = List.of(executeWorker(orchestratorResponse.tasks().get(0), userPrompt, username));
            } else {
                List<CompletableFuture<String>> futures = orchestratorResponse.tasks().stream()
                        .map(task -> CompletableFuture.supplyAsync(
                                () -> executeWorker(task, userPrompt, username), workerExecutor))
                        .toList();
                workerResponses = futures.stream().map(CompletableFuture::join).toList();
            }
            logger.info("All {} workers completed in {}ms", workerResponses.size(), System.currentTimeMillis() - workersStart);

            // Step 3: Synthesize — text-only options (no tool schemas), include worker memory
            String synthesisPrompt = String.format("""
                    Combine these worker responses into a coherent answer for: "%s"
                    
                    Analysis: %s
                    
                    Worker Results:
                    %s
                    
                    Provide a clear, unified response.
                    """, userPrompt, orchestratorResponse.analysis(),
                    String.join("\n\n", workerResponses));

            long synthesisStart = System.currentTimeMillis();
            String finalResponse = chatClient.prompt(new Prompt(synthesisPrompt, textOnlyOptions))
                    .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, username + "-synthesis"))
                    .call().chatResponse().getResult().getOutput().getText();

            logger.info("Synthesis completed in {}ms. Total: {}ms",
                    System.currentTimeMillis() - synthesisStart, System.currentTimeMillis() - startTime);
            return finalResponse;

        } catch (Exception e) {
            logger.error("Execution failed: {}", e.getMessage(), e);
            throw e;
        }
    }

    private String executeWorker(Task task, String userPrompt, String username) {
        String workerConvId = username + "-worker-" + task.id();
        logger.info("Worker START: {} (convId: {})", task.worker(), workerConvId);
        long workerStart = System.currentTimeMillis();

        String workerInput = WORKER_PROMPT
                .replace("{task_description}", task.description())
                .replace("{original_task}", userPrompt)
                .replace("{worker_type}", task.worker());

        try {
            String response = chatClient.prompt(new Prompt(workerInput, toolOptions))
                    .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, workerConvId))
                    .call().chatResponse().getResult().getOutput().getText();

            logger.info("Worker SUCCESS: {} in {}ms", task.worker(), System.currentTimeMillis() - workerStart);
            return response;
        } catch (Exception e) {
            logger.error("Worker FAILED: {} - {}", task.worker(), e.getMessage());
            return "Error in " + task.worker() + ": " + e.getMessage();
        }
    }
}
