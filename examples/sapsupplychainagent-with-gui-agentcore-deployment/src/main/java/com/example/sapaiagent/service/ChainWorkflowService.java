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
import org.springframework.ai.mcp.SyncMcpToolCallbackProvider;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.support.ToolCallbacks;
import org.springframework.stereotype.Service;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

@Service
public class ChainWorkflowService {

    private static final Logger logger = LoggerFactory.getLogger(ChainWorkflowService.class);

    private static final String SYSTEM_PROMPT = """
        You are an SAP Supply Chain assistant with access to tools for SAP APIs, date/time, weather, and AWS knowledge base.
        Today's date is %s. Always use this as the reference for relative dates (next week, tomorrow, etc.).
        You have MCP tools available for answering AWS-related questions — use them when asked about AWS services, best practices, or architecture.
        Respond concisely. Limit tabular data to the most relevant records.
        """;

    /**
     * Chain workflow steps with differentiated tool configurations:
     * - Steps 1 & 2 use toolOptions (LLM can invoke tools autonomously)
     * - Step 3 uses textOnlyOptions (pure formatting, no tool overhead)
     */
    private static final String FINAL_MARKER = "[FINAL]";

    private static final String[] CHAIN_PROMPTS = {
        // Step 1: Analyze, select SAP API if needed, or answer directly for non-SAP queries
        """
        Analyze the user request below.
        
        If it requires SAP data (freight, inventory, warehouse, supply chain):
          - Call selectApi with a clear description of the SAP data needed.
          - If it also involves weather or date/time, call those tools too.
          - Return ALL tool results as-is — do not summarize yet.
        
        If it does NOT require SAP data (greetings, weather, date/time, AWS questions, general questions):
          - Use any relevant tools (weather, date/time, AWS knowledge base) and answer the user directly.
          - Prefix your final answer with """ + "\"" + FINAL_MARKER + "\"" + """
        
        User request: %s
        """,
        // Step 2: Execute the SAP API using details from Step 1
        """
        From the output below, extract apiTitle, baseUrl, and endpoint, then call executeApi.
        IMPORTANT: Return BOTH the API response AND any other context (weather, date/time data)
        from the previous step. Do not discard non-SAP data.
        
        Previous step output:
        %s
        """,
        // Step 3: Format final response (no tools needed)
        """
        Using the data below, provide a clear and concise answer to the user's original request.
        Format any tabular data neatly. Combine SAP data with any weather/date context if present.
        
        Original request: %s
        
        Data:
        %s
        """
    };

    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;
    private final OrchestrationChatOptions textOnlyOptions;

    public ChainWorkflowService(
            DateTimeTools dateTimeTools,
            WeatherTools weatherTools,
            SyncMcpToolCallbackProvider mcpToolProvider,
            SAPOdataApiSelectorTool apiSelector,
            SAPApiExecutorTool apiExecutor) {

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        // Tool-enabled options for Steps 1 & 2
        this.toolOptions = new OrchestrationChatOptions(llmConfig);
        var toolCallbacks = new ArrayList<>(List.of(ToolCallbacks.from(dateTimeTools, weatherTools, apiSelector, apiExecutor)));
        toolCallbacks.addAll(List.of(mcpToolProvider.getToolCallbacks()));
        this.toolOptions.setToolCallbacks(toolCallbacks);
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

        // Text-only options for Step 3 (no tool schemas = faster)
        this.textOnlyOptions = new OrchestrationChatOptions(llmConfig);

        var chatMemory = MessageWindowChatMemory.builder()
                .chatMemoryRepository(new InMemoryChatMemoryRepository()).build();

        this.chatClient = ChatClient.builder(chatModel)
                .defaultSystem(String.format(SYSTEM_PROMPT, java.time.LocalDate.now()))
                .defaultAdvisors(MessageChatMemoryAdvisor.builder(chatMemory).build())
                .build();
    }

    public String execute(String userPrompt, String username) {
        long startTime = System.currentTimeMillis();
        logger.info("=== EXECUTION START === User: {}, Prompt: {}", username, userPrompt);

        try {
            // Step configs: prompt template + chat options per step
            var steps = List.of(
                    Map.entry(CHAIN_PROMPTS[0], toolOptions),
                    Map.entry(CHAIN_PROMPTS[1], toolOptions),
                    Map.entry(CHAIN_PROMPTS[2], textOnlyOptions)
            );

            String response = userPrompt;
            String step1Output = null;
            for (int i = 0; i < steps.size(); i++) {
                long stepStart = System.currentTimeMillis();
                var step = steps.get(i);

                // Step 3 gets original prompt + all accumulated data (step 1 + step 2 outputs)
                String prompt;
                if (i == steps.size() - 1) {
                    String allData = step1Output != null
                            ? "Step 1 (analysis/weather/context):\n" + step1Output + "\n\nStep 2 (SAP API data):\n" + response
                            : response;
                    prompt = String.format(step.getKey(), userPrompt, allData);
                } else {
                    prompt = String.format(step.getKey(), response);
                }

                if (i == 0) step1Output = null; // will be set after step 1 completes

                // Use per-step conversation IDs
                // from prior steps bleeding into the next step's conversation history.
                // The SAP AI Core orchestration layer rejects assistant messages that contain
                // only tool_use blocks without text content.
                String stepConversationId = username + "-chain-step-" + (i + 1);
                response = chatClient.prompt(new Prompt(prompt, step.getValue()))
                        .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, stepConversationId))
                        .call().chatResponse().getResult().getOutput().getText();

                logger.info("Chain Step {} completed in {}ms, output length: {} chars", i + 1,
                        System.currentTimeMillis() - stepStart, response.length());
                logger.debug("Chain Step {} output: {}", i + 1,
                        response.substring(0, Math.min(500, response.length())));

                // Preserve Step 1 output for Step 3's full context
                if (i == 0) step1Output = response;

                // Short-circuit: if Step 1 answered directly (non-SAP query), skip remaining steps
                if (response.startsWith(FINAL_MARKER)) {
                    response = response.substring(FINAL_MARKER.length()).trim();
                    logger.info("Non-SAP query — short-circuited after Step 1. Total: {}ms",
                            System.currentTimeMillis() - startTime);
                    return response;
                }
            }

            logger.info("=== EXECUTION END === Total: {}ms", System.currentTimeMillis() - startTime);
            return response;

        } catch (Exception e) {
            logger.error("=== EXECUTION FAILED === User: {}, Error: {}", username, e.getMessage(), e);
            throw new RuntimeException("Chain workflow failed: " + e.getMessage(), e);
        }
    }
}
