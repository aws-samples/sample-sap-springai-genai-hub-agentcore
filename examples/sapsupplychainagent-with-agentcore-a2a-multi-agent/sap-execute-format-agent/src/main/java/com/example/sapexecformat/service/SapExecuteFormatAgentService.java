/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapexecformat.service;

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
public class SapExecuteFormatAgentService implements AgentExecutor {

    private static final Logger log = LoggerFactory.getLogger(SapExecuteFormatAgentService.class);

    private static final String SYSTEM_PROMPT = """
            You are a specialized SAP Execute and Format agent.
            You receive SAP API details (apiTitle, baseUrl, endpoint) and must:
            1. Call the executeApi tool with the provided baseUrl and endpoint.
            2. Return a concise, human-readable summary of the result. Do NOT make a second tool call.

            Rules: max 5 table rows, max 800 characters total, most relevant fields only.
            """;

    private final AgentCard agentCard;
    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;

    public SapExecuteFormatAgentService(
            SAPApiExecutorTool apiExecutorTool,
            @Value("${agent.base-url:http://localhost:${server.port:9092}}") String baseUrl) {

        this.agentCard = new AgentCard(
                "sap-execute-format-agent",
                "Specialized SAP Execute and Format agent. Executes SAP OData API calls and formats results into readable responses.",
                baseUrl,
                "1.0.0",
                List.of(
                        new AgentSkill("sap-execute-format", "Execute SAP API and format response",
                                "Executes a SAP OData API call using provided API details and returns a formatted human-readable response",
                                List.of("sap", "execute", "format"),
                                List.of("Execute SAP freight booking API and show results"))
                )
        );

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        this.toolOptions = new OrchestrationChatOptions(llmConfig);
        this.toolOptions.setToolCallbacks(List.of(ToolCallbacks.from(apiExecutorTool)));
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
        log.info("SapExecuteFormatAgent executing: sessionId={}, message={}", sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));
        try {
            // Single LLM call: execute tool + format in one turn (saves one LLM round-trip)
            return chatClient.prompt(new Prompt(userMessage, toolOptions))
                    .call().chatResponse().getResult().getOutput().getText();
        } catch (Exception e) {
            log.error("SapExecuteFormatAgent failed: {}", e.getMessage(), e);
            throw new RuntimeException("SapExecuteFormatAgent execution failed: " + e.getMessage(), e);
        }
    }
}
