/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.service;

import com.sap.ai.sdk.orchestration.OrchestrationAiModel;
import com.sap.ai.sdk.orchestration.OrchestrationModuleConfig;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatModel;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatOptions;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.MessageChatMemoryAdvisor;
import org.springframework.ai.chat.memory.ChatMemoryRepository;
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

import static com.example.sapaiagent.config.ToolSpanAspect.GEN_AI_SYSTEM;

@Service
public class ChainWorkflowService {

    private static final Logger logger = LoggerFactory.getLogger(ChainWorkflowService.class);
    private static final String AGENT_NAME = System.getenv("AGENT_NAME") != null
            ? System.getenv("AGENT_NAME") : "sap-supply-chain-agent";
    private static final String MODEL_ID = OrchestrationAiModel.CLAUDE_4_5_SONNET.getName();

    private static final String SYSTEM_PROMPT = """
        You are an SAP Supply Chain assistant with access to tools for SAP APIs, date/time, weather, AWS knowledge base, and a product catalog.
        Today's date is %s. Always use this as the reference for relative dates (next week, tomorrow, etc.).
        You have MCP tools available:
        - For AWS-related questions: use AWS knowledge base MCP tools.
        - For product catalog operations (create, read, update, delete, search products): use the product catalog MCP tools.
        Respond concisely. Limit tabular data to the most relevant records.
        """;

    /**
     * Chain workflow steps with differentiated tool configurations:
     * - Steps 1 & 2 use toolOptions (LLM can invoke tools autonomously)
     * - Step 3 uses textOnlyOptions (pure formatting, no tool overhead)
     *
     * Memory is managed via MessageChatMemoryAdvisor with a single conversation ID
     * per user (the username). The advisor is only attached on Step 3 (or Step 1 for
     * short-circuited non-SAP queries) so that only the final user prompt + response
     * are saved — not intermediate chain step prompts.
     *
     * When deployed with AGENTCORE_MEMORY_MEMORY_ID, chatMemoryRepository is
     * AgentCoreShortTermMemoryRepository (auto-configured by the library).
     * Locally (no env var), it's null — fall back to InMemoryChatMemoryRepository.
     */
    private static final String FINAL_MARKER = "[FINAL]";

    private static final String[] CHAIN_PROMPTS = {
        // Step 1: Analyze, select SAP API if needed, route product catalog queries, or answer directly
        """
        Analyze the user request below.

        If it requires SAP data (freight, inventory, warehouse, supply chain):
          - Call selectApi with a clear description of the SAP data needed.
          - If it also involves weather or date/time, call those tools too.
          - Return ALL tool results as-is — do not summarize yet.

        If it requires product catalog operations (listing products, searching products,
        creating/updating/deleting products, checking product stock or price):
          - Call the appropriate product catalog MCP tool(s) directly.
          - Return ALL tool results as-is — do not summarize yet.

        If it does NOT require SAP data or product catalog operations (greetings, weather, date/time, AWS questions, general questions):
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
    private final Tracer tracer;

    public ChainWorkflowService(
            DateTimeTools dateTimeTools,
            WeatherTools weatherTools,
            SyncMcpToolCallbackProvider mcpToolProvider,
            SAPOdataApiSelectorTool apiSelector,
            SAPApiExecutorTool apiExecutor,
            Tracer tracer,
            @org.springframework.lang.Nullable ChatMemoryRepository chatMemoryRepository) {
        this.tracer = tracer;

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
                .chatMemoryRepository(chatMemoryRepository != null ? chatMemoryRepository : new InMemoryChatMemoryRepository())
                .maxMessages(20)
                .build();

        this.chatClient = ChatClient.builder(chatModel)
                .defaultSystem(String.format(SYSTEM_PROMPT, java.time.LocalDate.now()))
                .defaultAdvisors(MessageChatMemoryAdvisor.builder(chatMemory).build())
                .build();
    }

    public String execute(String userPrompt, String username, String sessionId) {
        Span agentSpan = tracer.spanBuilder("invoke_agent " + AGENT_NAME)
                .setAttribute("gen_ai.system", GEN_AI_SYSTEM)
                .setAttribute("gen_ai.agent.name", AGENT_NAME)
                .setAttribute("gen_ai.operation.name", "invoke_agent")
                .setAttribute("gen_ai.request.model", MODEL_ID)
                .setAttribute("gen_ai.prompt", userPrompt.substring(0, Math.min(500, userPrompt.length())))
                .setAttribute("user.id", username)
                .setAttribute("session.id", sessionId)
                .startSpan();

        Context agentContext = Baggage.builder().put("session.id", sessionId).build()
                .storeInContext(Context.current().with(agentSpan));

        try (Scope agentScope = agentContext.makeCurrent()) {
            logger.info("=== EXECUTION START === User: {}, Prompt: {}", username, userPrompt);

            String[] stepNames = {"1-analyze-select", "2-execute-api", "3-format-response"};
            var steps = List.of(
                    Map.entry(CHAIN_PROMPTS[0], toolOptions),
                    Map.entry(CHAIN_PROMPTS[1], toolOptions),
                    Map.entry(CHAIN_PROMPTS[2], textOnlyOptions)
            );

            String response = userPrompt;
            String step1Output = null;

            for (int i = 0; i < steps.size(); i++) {
                var step = steps.get(i);

                String prompt;
                if (i == steps.size() - 1) {
                    String allData = step1Output != null
                            ? "Step 1 (analysis/weather/context):\n" + step1Output + "\n\nStep 2 (SAP API data):\n" + response
                            : response;
                    prompt = String.format(step.getKey(), userPrompt, allData);
                } else {
                    prompt = String.format(step.getKey(), response);
                }

                Span stepSpan = tracer.spanBuilder("execute_agent_step " + stepNames[i])
                        .setAttribute("gen_ai.system", GEN_AI_SYSTEM)
                        .setAttribute("gen_ai.agent.name", AGENT_NAME)
                        .setAttribute("gen_ai.operation.name", "execute_agent_step")
                        .setAttribute("gen_ai.request.model", MODEL_ID)
                        .setAttribute("gen_ai.agent.step", stepNames[i])
                        .startSpan();

                try (var stepScope = stepSpan.makeCurrent()) {
                    long stepStart = System.currentTimeMillis();

                    // Attach memory advisor only on Step 3 (text-only, guaranteed text content).
                    // Steps 1 & 2 use tool-enabled options where the LLM may produce
                    // tool_use-only assistant messages with empty text — AgentCore Memory
                    // rejects these with a ValidationException.
                    var call = chatClient.prompt(new Prompt(prompt, step.getValue()));
                    if (i == steps.size() - 1) {
                        call = call.advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, username));
                    }
                    response = call.call().chatResponse().getResult().getOutput().getText();

                    stepSpan.setAttribute("gen_ai.agent.step.duration_ms", System.currentTimeMillis() - stepStart);
                    stepSpan.setAttribute("gen_ai.completion.size", response.length());

                    logger.info("Chain Step {} completed in {}ms, output length: {} chars",
                            i + 1, System.currentTimeMillis() - stepStart, response.length());

                    if (i == 0) step1Output = response;

                    if (response.startsWith(FINAL_MARKER)) {
                        response = response.substring(FINAL_MARKER.length()).trim();
                        stepSpan.setAttribute("gen_ai.agent.short_circuit", true);
                        agentSpan.setAttribute("gen_ai.agent.short_circuit", true);
                        logger.info("Non-SAP query — short-circuited after Step 1");
                        return response;
                    }
                } catch (Exception e) {
                    stepSpan.setStatus(StatusCode.ERROR, e.getMessage());
                    stepSpan.recordException(e);
                    throw e;
                } finally {
                    stepSpan.end();
                }
            }

            agentSpan.setAttribute("gen_ai.completion.size", response.length());
            logger.info("=== EXECUTION END ===");
            return response;

        } catch (Exception e) {
            agentSpan.setStatus(StatusCode.ERROR, e.getMessage());
            agentSpan.recordException(e);
            logger.error("=== EXECUTION FAILED === User: {}, Error: {}", username, e.getMessage(), e);
            throw new RuntimeException("Chain workflow failed: " + e.getMessage(), e);
        } finally {
            agentSpan.end();
        }
    }
}
