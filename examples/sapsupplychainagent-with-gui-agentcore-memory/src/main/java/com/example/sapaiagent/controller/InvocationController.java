/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.controller;

import com.example.sapaiagent.model.InvocationRequest;
import com.example.sapaiagent.service.SAPAIOrchestrationService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springaicommunity.agentcore.annotation.AgentCoreInvocation;
import org.springaicommunity.agentcore.context.AgentCoreContext;
import org.springaicommunity.agentcore.context.AgentCoreHeaders;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Flux;

@RestController
public class InvocationController {

    private static final Logger log = LoggerFactory.getLogger(InvocationController.class);
    private static final String BEARER_PREFIX = "Bearer ";
    private static final String ANONYMOUS_USER = "ANONYMOUS_USER";

    private final SAPAIOrchestrationService orchestrationService;

    public InvocationController(SAPAIOrchestrationService orchestrationService) {
        this.orchestrationService = orchestrationService;
        log.info("InvocationController initialized with orchestration service");
    }

    @AgentCoreInvocation
    public Flux<String> handleUserPrompt(InvocationRequest request, AgentCoreContext agentCoreContext) {

        log.info("=== Invocation received ===");
        log.info("Prompt: {}", request.prompt());

        String userId = extractUserIdFromContext(agentCoreContext);
        log.info("User Id: {}", userId);

        String sessionId = extractSessionId(agentCoreContext, userId);
        log.info("Session Id: {}", sessionId);

        return Flux.defer(() -> {
            try {
                String result = orchestrationService.chatStream(request.prompt(), userId, sessionId).blockFirst();
                return Flux.just(result);
            } catch (Exception e) {
                log.error("=== INVOCATION FAILED === Prompt: {}, UserId: {}, SessionId: {}",
                    request.prompt(), userId, sessionId, e);
                return Flux.just("I apologize, but I encountered an error processing your request. Please try again.");
            }
        });
    }

    /**
     * Extracts the session ID for OTEL trace correlation.
     * AgentCore sets session.id on its own infrastructure-level spans from the
     * runtimeSessionId (X-Amzn-Bedrock-AgentCore-Runtime-Session-Id header).
     * We read the same header so our application-level spans carry the same value.
     */
    private String extractSessionId(AgentCoreContext context, String userId) {
        String runtimeSessionId = context.getHeader("X-Amzn-Bedrock-AgentCore-Runtime-Session-Id");
        if (runtimeSessionId != null && !runtimeSessionId.isBlank()) {
            log.info("Session ID from AgentCore runtime header: {}", runtimeSessionId);
            return runtimeSessionId;
        }
        log.info("Session ID fallback to userId: {}", userId);
        return userId;
    }

    private String extractUserIdFromContext(AgentCoreContext context) {

        // AgentCore's JWT authorizer injects this header from the validated token.
        // It is the most reliable user identifier — use it when available.
        String userId = context.getHeader(AgentCoreHeaders.USER_ID);
        if (userId != null && !userId.isBlank()) {
            log.info("User ID from AgentCore header: {}", userId);
            return userId;
        }

        // Fallback: parse the sub claim from the Cognito JWT in the Authorization header.
        // Required for local testing (no AgentCore JWT authorizer) and as a safety net.
        String authHeader = context.getHeader(AgentCoreHeaders.AUTHORIZATION);
        log.info("Authorization header present: {}", authHeader != null);

        if (authHeader == null) return ANONYMOUS_USER;

        if (authHeader.startsWith(BEARER_PREFIX)) {
            String token = authHeader.substring(BEARER_PREFIX.length());
            try {
                String[] parts = token.split("\\.");
                if (parts.length > 1) {
                    // JWT payloads use base64url WITHOUT padding — add padding before decoding
                    String base64Payload = parts[1];
                    int padding = (4 - base64Payload.length() % 4) % 4;
                    base64Payload = base64Payload + "=".repeat(padding);
                    String payload = new String(java.util.Base64.getUrlDecoder().decode(base64Payload));
                    // Extract the stable 'sub' claim using Jackson (already on classpath via Spring Boot)
                    JsonNode node = new ObjectMapper().readTree(payload);
                    if (node.has("sub")) {
                        String sub = node.get("sub").asText();
                        log.info("User ID from JWT sub claim: {}", sub);
                        return sub;
                    }
                }
            } catch (Exception e) {
                log.warn("Failed to parse JWT: {}", e.getMessage());
            }
            return ANONYMOUS_USER;
        }
        // Non-Bearer header (e.g. plain username in local testing) — use as-is
        return authHeader;
    }
}
