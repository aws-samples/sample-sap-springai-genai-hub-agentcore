/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.orchestrator.controller;

import com.example.orchestrator.service.OrchestratorService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springaicommunity.agentcore.annotation.AgentCoreInvocation;
import org.springaicommunity.agentcore.context.AgentCoreContext;
import org.springaicommunity.agentcore.context.AgentCoreHeaders;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Flux;

/**
 * AgentCore-deployable controller for the Orchestrator Agent.
 * Uses {@code @AgentCoreInvocation} (replaces @PostMapping).
 *
 * Also accepts local REST requests via /invocations for local testing.
 */
@RestController
public class OrchestratorController {

    private static final Logger log = LoggerFactory.getLogger(OrchestratorController.class);
    private static final String BEARER_PREFIX = "Bearer ";
    private static final String ANONYMOUS_USER = "ANONYMOUS_USER";

    private final OrchestratorService orchestratorService;

    public OrchestratorController(OrchestratorService orchestratorService) {
        this.orchestratorService = orchestratorService;
    }

    @AgentCoreInvocation
    public Flux<String> handleUserPrompt(
            com.example.orchestrator.model.InvocationRequest request,
            AgentCoreContext agentCoreContext) {

        log.info("=== Orchestrator invocation received ===");
        log.info("Prompt: {}", request.prompt());

        String userId = extractUserId(agentCoreContext);

        // sessionId is set by the AgentCore system header
        // (X-Amzn-Bedrock-AgentCore-Runtime-Session-Id), which controls microVM
        // session routing and session.id on all OTEL spans. The same value is
        // propagated to A2A workers via ThreadLocal for distributed tracing and
        // isolation. Memory conversationId stays keyed on userId so long-term
        // context persists across devices for the same user.
        String sessionId = extractSessionId(agentCoreContext, userId);
        log.info("User: {}, Session: {}", userId, sessionId);

        // Execute synchronously first, then wrap in Flux.just() which completes immediately
        // when subscribed. This avoids Tomcat async dispatch, which fails to serialize
        // Flux<String> when AgentCoreInvocationsController declares Object as return type
        // (Jackson receives ResolvableType$EmptyType and throws IllegalArgumentException).
        // Flux.defer() triggers async dispatch; Flux.just(pre-computed) does not.
        try {
            String result = orchestratorService.execute(request.prompt(), userId, sessionId);
            return Flux.just(result);
        } catch (Exception e) {
            log.error("Orchestrator invocation failed for user {}: {}", userId, e.getMessage(), e);
            return Flux.just("I apologize, but I encountered an error processing your request. Please try again.");
        }
    }

    private String extractSessionId(AgentCoreContext context, String userId) {
        // AgentCore system header — set by the SDK's runtimeSessionId or by the GUI.
        // Controls microVM session routing AND session.id on all OTEL spans.
        // Also used as the A2A session ID propagated to worker agents.
        String sessionId = context.getHeader("X-Amzn-Bedrock-AgentCore-Runtime-Session-Id");
        if (sessionId != null && !sessionId.isBlank()) return sessionId;
        // No session header — fall back to userId (single-device or local testing)
        return userId;
    }

    private String extractUserId(AgentCoreContext context) {
        String userId = context.getHeader(AgentCoreHeaders.USER_ID);
        if (userId != null && !userId.isBlank()) return userId;

        String authHeader = context.getHeader(AgentCoreHeaders.AUTHORIZATION);
        if (authHeader == null) return ANONYMOUS_USER;

        if (authHeader.startsWith(BEARER_PREFIX)) {
            String token = authHeader.substring(BEARER_PREFIX.length());
            try {
                String[] parts = token.split("\\.");
                if (parts.length > 1) {
                    String base64Payload = parts[1];
                    int padding = (4 - base64Payload.length() % 4) % 4;
                    base64Payload = base64Payload + "=".repeat(padding);
                    String payload = new String(java.util.Base64.getUrlDecoder().decode(base64Payload));
                    JsonNode node = new ObjectMapper().readTree(payload);
                    if (node.has("sub")) {
                        return node.get("sub").asText();
                    }
                }
            } catch (Exception e) {
                log.warn("Failed to parse JWT: {}", e.getMessage());
            }
            return ANONYMOUS_USER;
        }
        return authHeader;
    }
}
