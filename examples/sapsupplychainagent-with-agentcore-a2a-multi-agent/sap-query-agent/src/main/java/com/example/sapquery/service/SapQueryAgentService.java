/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapquery.service;

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
import org.springframework.ai.support.ToolCallbacks;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class SapQueryAgentService implements AgentExecutor {

    private static final Logger log = LoggerFactory.getLogger(SapQueryAgentService.class);

    private static final String SYSTEM_PROMPT = """
            You are a specialized SAP API Query agent.
            Your role is to analyze supply chain requests and identify the correct SAP OData API
            and specific endpoint to retrieve the required data.

            Use the selectApi tool to look up available SAP APIs and find the best match.
            Return your response as JSON with: apiTitle, baseUrl, endpoint, httpMethod, and reasoning.
            """;

    private final AgentCard agentCard;
    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;

    public SapQueryAgentService(
            SAPOdataApiSelectorTool apiSelectorTool,
            @Value("${agent.base-url:http://localhost:${server.port:9091}}") String baseUrl) {

        this.agentCard = new AgentCard(
                "sap-query-agent",
                "Specialized SAP Query agent. Identifies the correct SAP OData API and endpoint for supply chain data retrieval (freight, inventory, warehouse stock).",
                baseUrl,
                "1.0.0",
                List.of(
                        new AgentSkill("sap-query", "Select SAP API and endpoint",
                                "Analyzes a supply chain query and returns the matching SAP OData API details as JSON",
                                List.of("sap", "odata", "api-selection"),
                                List.of("Find the SAP API for freight booking charges"))
                )
        );

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        this.toolOptions = new OrchestrationChatOptions(llmConfig);
        this.toolOptions.setToolCallbacks(List.of(ToolCallbacks.from(apiSelectorTool)));
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

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
        log.info("SapQueryAgent executing: sessionId={}, message={}", sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));
        try {
            return chatClient.prompt(new Prompt(userMessage, toolOptions))
                    .call().chatResponse().getResult().getOutput().getText();
        } catch (Exception e) {
            log.error("SapQueryAgent failed: {}", e.getMessage(), e);
            throw new RuntimeException("SapQueryAgent execution failed: " + e.getMessage(), e);
        }
    }
}
