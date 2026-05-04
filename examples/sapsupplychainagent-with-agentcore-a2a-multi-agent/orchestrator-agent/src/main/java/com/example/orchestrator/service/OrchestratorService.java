/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.orchestrator.service;

import com.example.a2a.client.A2AClient;
import com.example.a2a.context.A2ASessionContext;
import com.example.a2a.tool.RemoteAgentToolCallback;
import com.example.orchestrator.config.A2AAgentsConfig;
import com.sap.ai.sdk.orchestration.OrchestrationAiModel;
import com.sap.ai.sdk.orchestration.OrchestrationModuleConfig;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatModel;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatOptions;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.MessageChatMemoryAdvisor;
import org.springframework.ai.chat.memory.ChatMemoryRepository;
import org.springframework.ai.chat.memory.InMemoryChatMemoryRepository;
import org.springframework.ai.chat.memory.MessageWindowChatMemory;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.lang.Nullable;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Service
public class OrchestratorService {

    private static final Logger log = LoggerFactory.getLogger(OrchestratorService.class);

    private static final String SYSTEM_PROMPT = """
            You are an intelligent SAP Supply Chain Orchestrator.
            You MUST route every request to the appropriate agent(s) using your tools. NEVER answer from your own knowledge.

            - SAP supply chain data (freight, inventory, warehouse): call sap_query_agent first, then sap_execute_format_agent.
            - Date/time or weather questions: ALWAYS call date_weather_agent. Never guess dates or times.
            - AWS knowledge base or product catalog: call mcp_tools_agent.
            - Greetings and simple conversation: you may respond directly.

            For ANY factual question, you MUST use a tool. Do not rely on your training data.
            Return the agent response directly without rephrasing.
            Keep your final answer under 1000 characters.
            IMPORTANT: Never mention internal tool names, agent names, or system internals in your response.
            Present information as if you retrieved it yourself.
            """;

    private final A2AAgentsConfig agentsConfig;
    private final MessageWindowChatMemory chatMemory;
    private ChatClient chatClient;
    private OrchestrationChatOptions toolOptions;

    public OrchestratorService(A2AAgentsConfig agentsConfig,
                                @Nullable ChatMemoryRepository chatMemoryRepository) {
        this.agentsConfig = agentsConfig;
        // When AGENTCORE_MEMORY_MEMORY_ID is set, spring-ai-agentcore-memory auto-configures
        // AgentCoreShortTermMemoryRepository as the ChatMemoryRepository bean.
        // Locally (no env var), fall back to InMemoryChatMemoryRepository.
        this.chatMemory = MessageWindowChatMemory.builder()
                .chatMemoryRepository(chatMemoryRepository != null
                        ? chatMemoryRepository
                        : new InMemoryChatMemoryRepository())
                .maxMessages(20)
                .build();
    }

    @PostConstruct
    public void initialize() {
        log.info("Discovering A2A worker agents...");

        List<ToolCallback> toolCallbacks = new ArrayList<>();

        for (var entry : agentsConfig.getAgents().entrySet()) {
            String agentName = entry.getKey();
            String agentUrl = entry.getValue().getUrl();

            try {
                log.info("Discovering agent '{}' at {}", agentName, agentUrl);
                var a2aClient = new A2AClient(agentUrl, agentName);
                var agentCard = a2aClient.fetchAgentCard();

                toolCallbacks.add(new RemoteAgentToolCallback(agentCard, a2aClient));
                log.info("Registered agent '{}' with {} skills", agentCard.name(),
                        agentCard.skills() != null ? agentCard.skills().size() : 0);
            } catch (Exception e) {
                log.error("Failed to discover agent '{}' at {}: {}", agentName, agentUrl, e.getMessage());
                // Continue with other agents — allow partial startup
            }
        }

        if (toolCallbacks.isEmpty()) {
            log.warn("No A2A agents discovered! Check a2a.agents.*.url configuration.");
        }

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        this.toolOptions = new OrchestrationChatOptions(llmConfig);
        this.toolOptions.setToolCallbacks(toolCallbacks);
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

        this.chatClient = ChatClient.builder(chatModel)
                .defaultSystem(SYSTEM_PROMPT)
                .defaultAdvisors(MessageChatMemoryAdvisor.builder(chatMemory).build())
                .build();

        log.info("OrchestratorService initialized with {} agent tools", toolCallbacks.size());
    }

    /**
     * @param userId    JWT sub claim — keys AgentCore Memory so context persists across devices.
     * @param sessionId userId + UUID from X-Session-Id header — unique per browser login,
     *                  propagated to all A2A workers via ThreadLocal for tracing and isolation.
     */
    public String execute(String userMessage, String userId, String sessionId) {
        log.info("Orchestrator executing: userId={}, sessionId={}, message={}", userId, sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));

        // Attach userId and sessionId to the current OTEL span so they appear
        // as searchable attributes in X-Ray / CloudWatch traces.
        var span = io.opentelemetry.api.trace.Span.current();
        span.setAttribute("user.id", userId);
        span.setAttribute("session.id", sessionId);

        // Publish sessionId into a ThreadLocal so RemoteAgentToolCallback can forward it
        // to every worker agent. ToolCallback.call(String) has no session parameter, and
        // setInternalToolExecutionEnabled(true) guarantees tool calls run on this same thread.
        A2ASessionContext.set(sessionId);
        try {
            // Memory advisor keyed on userId so long-term context follows the user across
            // devices. A2A worker calls use sessionId (unique per login) for isolation.
            return chatClient.prompt(new Prompt(userMessage, toolOptions))
                    .advisors(a -> a.param(MessageWindowChatMemory.CONVERSATION_ID, userId))
                    .call().chatResponse().getResult().getOutput().getText();
        } catch (Exception e) {
            log.error("Orchestrator failed: {}", e.getMessage(), e);
            throw new RuntimeException("Orchestrator execution failed: " + e.getMessage(), e);
        } finally {
            A2ASessionContext.clear();
        }
    }
}
