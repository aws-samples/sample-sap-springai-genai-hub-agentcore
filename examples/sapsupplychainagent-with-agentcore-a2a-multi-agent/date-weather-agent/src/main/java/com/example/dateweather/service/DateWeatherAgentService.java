/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.dateweather.service;

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
public class DateWeatherAgentService implements AgentExecutor {

    private static final Logger log = LoggerFactory.getLogger(DateWeatherAgentService.class);

    private static final String SYSTEM_PROMPT = """
            You are a specialized Date and Weather assistant.
            Today's date is %s.
            Answer questions about current date/time in any timezone and weather forecasts for any city.
            Use the available tools to get accurate information.
            Be concise and precise in your responses.
            """;

    private final AgentCard agentCard;
    private final ChatClient chatClient;
    private final OrchestrationChatOptions toolOptions;

    public DateWeatherAgentService(
            DateTimeTools dateTimeTools,
            WeatherTools weatherTools,
            @Value("${server.port:9093}") int port,
            @Value("${agent.base-url:http://localhost:${server.port:9093}}") String baseUrl) {

        this.agentCard = new AgentCard(
                "date-weather-agent",
                "Specialized agent for date/time and weather queries. Use for current date/time in any timezone and weather forecasts.",
                baseUrl,
                "1.0.0",
                List.of(
                        new AgentSkill("datetime", "Get current date/time",
                                "Returns the current date and time in any specified timezone",
                                List.of("datetime", "timezone"), List.of("What time is it in Tokyo?")),
                        new AgentSkill("weather", "Get weather forecast",
                                "Returns weather forecast for any city on a specified date",
                                List.of("weather", "forecast"), List.of("What's the weather in Paris tomorrow?"))
                )
        );

        var chatModel = new OrchestrationChatModel();
        var llmConfig = new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET);

        this.toolOptions = new OrchestrationChatOptions(llmConfig);
        this.toolOptions.setToolCallbacks(List.of(ToolCallbacks.from(dateTimeTools, weatherTools)));
        this.toolOptions.setInternalToolExecutionEnabled(Boolean.TRUE);

        this.chatClient = ChatClient.builder(chatModel)
                .defaultSystem(String.format(SYSTEM_PROMPT, java.time.LocalDate.now()))
                .build();
    }

    @Override
    public AgentCard getAgentCard() {
        return agentCard;
    }

    @Override
    public String execute(String userMessage, String sessionId) {
        log.info("DateWeatherAgent executing: sessionId={}, message={}", sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));
        try {
            return chatClient.prompt(new Prompt(userMessage, toolOptions))
                    .call().chatResponse().getResult().getOutput().getText();
        } catch (Exception e) {
            log.error("DateWeatherAgent failed: {}", e.getMessage(), e);
            throw new RuntimeException("DateWeatherAgent execution failed: " + e.getMessage(), e);
        }
    }
}
