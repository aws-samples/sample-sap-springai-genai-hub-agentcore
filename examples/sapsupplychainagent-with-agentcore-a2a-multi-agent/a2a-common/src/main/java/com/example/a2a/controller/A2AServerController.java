/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.a2a.controller;

import com.example.a2a.model.A2ARequest;
import com.example.a2a.model.A2AResponse;
import com.example.a2a.model.AgentCard;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.ApplicationContext;
import org.springframework.web.bind.annotation.*;

/**
 * A2A protocol server endpoints — imported via {@code @Import(A2AServerController.class)}
 * on each agent's {@code @SpringBootApplication} class.
 *
 * Endpoints:
 *   GET  /.well-known/agent-card.json   — agent discovery
 *   POST /                              — JSON-RPC 2.0 message/send
 */
@RestController
public class A2AServerController {

    private static final Logger log = LoggerFactory.getLogger(A2AServerController.class);

    private final ApplicationContext applicationContext;

    public A2AServerController(ApplicationContext applicationContext) {
        this.applicationContext = applicationContext;
    }

    /** Agent card discovery endpoint per A2A spec. */
    @GetMapping("/.well-known/agent-card.json")
    public AgentCard getAgentCard() {
        return getAgentExecutor().getAgentCard();
    }

    /** Health check endpoint required by AgentCore for A2A protocol. */
    @GetMapping("/ping")
    public String ping() {
        return "pong";
    }

    /** A2A JSON-RPC 2.0 message/send endpoint. */
    @PostMapping("/")
    public A2AResponse handleMessage(@RequestBody A2ARequest request) {
        log.info("A2A request received: method={}, sessionId={}", request.method(),
                request.params() != null ? request.params().sessionId() : null);

        // JSON-RPC 2.0 protocol validation
        if (request.requestId() == null) {
            return new A2AResponse("2.0", null, null,
                    new A2AResponse.Error(-32600, "Invalid request: missing id"));
        }

        if (!"message/send".equals(request.method())) {
            return new A2AResponse("2.0", request.requestId(), null,
                    new A2AResponse.Error(-32601, "Method not found: " + request.method()));
        }

        if (request.params() == null || request.params().messages() == null
                || request.params().messages().isEmpty()) {
            return new A2AResponse("2.0", request.requestId(), null,
                    new A2AResponse.Error(-32602, "Invalid params: messages required"));
        }

        try {
            var params = request.params();
            String userMessage = params.messages().stream()
                    .filter(m -> "user".equals(m.role()))
                    .map(m -> m.content())
                    .reduce("", (a, b) -> a.isEmpty() ? b : a + "\n" + b);

            String sessionId = params.sessionId() != null ? params.sessionId() : "default";

            log.info("Executing A2A request: sessionId={}, message={}", sessionId,
                    userMessage.substring(0, Math.min(100, userMessage.length())));

            String result = getAgentExecutor().execute(userMessage, sessionId);

            log.info("A2A response ready: sessionId={}, length={}", sessionId, result.length());
            return new A2AResponse("2.0", request.requestId(),
                    new A2AResponse.Result(result), null);

        } catch (Exception e) {
            log.error("A2A execution failed: {}", e.getMessage(), e);
            return new A2AResponse("2.0", request.requestId(), null,
                    new A2AResponse.Error(-32603, "Internal processing error"));
        }
    }

    private com.example.a2a.AgentExecutor getAgentExecutor() {
        return applicationContext.getBean(com.example.a2a.AgentExecutor.class);
    }
}
