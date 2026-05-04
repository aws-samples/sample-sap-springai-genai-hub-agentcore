/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.a2a.tool;

import com.example.a2a.client.A2AClient;
import com.example.a2a.context.A2ASessionContext;
import com.example.a2a.model.AgentCard;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.definition.ToolDefinition;

/**
 * A Spring AI {@link ToolCallback} that delegates to a remote A2A agent.
 *
 * The tool name and description are derived dynamically from the agent's
 * {@link AgentCard} at discovery time, so the orchestrator's LLM sees each
 * worker as a named tool with accurate capability description.
 *
 * Input schema: a simple JSON object with a single "input" string property,
 * since every A2A call is a free-text user message.
 */
public class RemoteAgentToolCallback implements ToolCallback {

    private static final Logger log = LoggerFactory.getLogger(RemoteAgentToolCallback.class);

    private static final String INPUT_SCHEMA = """
            {
              "type": "object",
              "properties": {
                "input": {
                  "type": "string",
                  "description": "The user message or task to send to this agent"
                }
              },
              "required": ["input"]
            }
            """;

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    private final AgentCard agentCard;
    private final A2AClient a2aClient;
    private final ToolDefinition toolDefinition;

    public RemoteAgentToolCallback(AgentCard agentCard, A2AClient a2aClient) {
        this.agentCard = agentCard;
        this.a2aClient = a2aClient;
        this.toolDefinition = ToolDefinition.builder()
                .name(sanitizeName(agentCard.name()))
                .description(buildDescription(agentCard))
                .inputSchema(INPUT_SCHEMA)
                .build();
    }

    @Override
    public ToolDefinition getToolDefinition() {
        return toolDefinition;
    }

    @Override
    public String call(String toolInput) {
        log.info("RemoteAgentToolCallback calling agent '{}': input={}",
                agentCard.name(), toolInput.substring(0, Math.min(100, toolInput.length())));
        try {
            // toolInput is JSON: {"input": "..."} — extract the input string
            String userMessage = extractInput(toolInput);
            // Inherit the authenticated user's session ID from the orchestrator so all
            // downstream A2A worker calls are tied to the same user session.
            // Falls back to a timestamp if called outside an orchestrator context.
            String sessionId = A2ASessionContext.get() != null
                    ? A2ASessionContext.get()
                    : "orchestrator-" + System.currentTimeMillis();
            return a2aClient.sendMessage(userMessage, sessionId);
        } catch (Exception e) {
            log.error("RemoteAgentToolCallback failed for agent '{}': {}", agentCard.name(), e.getMessage());
            return "Error calling agent " + agentCard.name() + ": " + e.getMessage();
        }
    }

    /** Tool name must be a valid Java identifier — replace hyphens and spaces. */
    private static String sanitizeName(String name) {
        return name.replaceAll("[^a-zA-Z0-9_]", "_");
    }

    private static String buildDescription(AgentCard card) {
        var sb = new StringBuilder(card.description());
        if (card.skills() != null && !card.skills().isEmpty()) {
            sb.append(" Capabilities: ");
            card.skills().forEach(s -> sb.append(s.name()).append(" (").append(s.description()).append("); "));
        }
        return sb.toString();
    }

    /** Extract "input" field from JSON tool input string. */
    private static String extractInput(String json) {
        try {
            String input = OBJECT_MAPPER.readTree(json).path("input").asText(null);
            return input != null ? input : json;
        } catch (Exception e) {
            return json; // fallback: treat as raw input
        }
    }
}
