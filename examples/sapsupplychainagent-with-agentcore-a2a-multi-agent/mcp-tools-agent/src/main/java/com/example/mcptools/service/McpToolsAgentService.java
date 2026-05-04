/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.mcptools.service;

import com.example.a2a.AgentExecutor;
import com.example.a2a.model.AgentCard;
import com.example.a2a.model.AgentSkill;
import com.sap.ai.sdk.orchestration.OrchestrationAiModel;
import com.sap.ai.sdk.orchestration.OrchestrationModuleConfig;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatModel;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.mcp.SyncMcpToolCallbackProvider;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

@Service
public class McpToolsAgentService implements AgentExecutor {

    private static final Logger log = LoggerFactory.getLogger(McpToolsAgentService.class);

    private static final String SYSTEM_PROMPT = """
            You are a specialized MCP Tools agent.
            You answer questions using AWS Knowledge Base and product catalog tools via MCP.
            Use the available MCP tools to search for relevant information.
            Provide accurate, well-sourced answers based on the tool results.
            """;

    private final AgentCard agentCard;
    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;

    public McpToolsAgentService(
            SyncMcpToolCallbackProvider mcpToolProvider,
            @Value("${agent.base-url:http://localhost:${server.port:9094}}") String baseUrl) {

        this.agentCard = new AgentCard(
                "mcp-tools-agent",
                "Specialized MCP Tools agent. Answers questions using AWS Knowledge Base and product catalog via MCP tools.",
                baseUrl,
                "1.0.0",
                List.of(
                        new AgentSkill("aws-knowledge", "Query AWS Knowledge Base",
                                "Searches AWS Knowledge Base for information about AWS services, best practices, and architecture",
                                List.of("aws", "knowledge", "mcp"),
                                List.of("What are AWS best practices for container security?")),
                        new AgentSkill("product-catalog", "Query product catalog",
                                "Searches the product catalog for product information",
                                List.of("product", "catalog", "mcp"),
                                List.of("Show me products in the electronics category"))
                )
        );

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        this.toolOptions = new OrchestrationChatOptions(llmConfig);

        List<ToolCallback> toolCallbacks = new ArrayList<>(Arrays.asList(mcpToolProvider.getToolCallbacks()));
        this.toolOptions.setToolCallbacks(toolCallbacks);
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

        log.info("MCP tools registered: {} total", toolCallbacks.size());
        for (ToolCallback tool : toolCallbacks) {
            log.info("  Tool: {} — {}", tool.getToolDefinition().name(),
                    tool.getToolDefinition().description().substring(0,
                            Math.min(100, tool.getToolDefinition().description().length())));
        }

        this.chatClient = ChatClient.builder(chatModel)
                .defaultSystem(SYSTEM_PROMPT)
                .build();
    }

    @Override
    public AgentCard getAgentCard() {
        return agentCard;
    }

    @Override
    public String execute(String userMessage, String sessionId) {
        log.info("McpToolsAgent executing: sessionId={}, message={}", sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));
        try {
            return chatClient.prompt(new Prompt(userMessage, toolOptions))
                    .call().chatResponse().getResult().getOutput().getText();
        } catch (Exception e) {
            log.error("McpToolsAgent failed: {}", e.getMessage(), e);
            throw new RuntimeException("McpToolsAgent execution failed: " + e.getMessage(), e);
        }
    }
}
