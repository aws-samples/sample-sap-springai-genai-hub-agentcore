package com.example.a2a.model;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * JSON-RPC 2.0 request envelope for A2A {@code message/send}.
 */
public record A2ARequest(
        String jsonrpc,
        String method,
        @JsonProperty("id") String requestId,
        Params params
) {
    public record Params(
            String sessionId,
            List<A2AMessage> messages
    ) {}

    public static A2ARequest messageSend(String sessionId, String userMessage) {
        return new A2ARequest(
                "2.0",
                "message/send",
                java.util.UUID.randomUUID().toString(),
                new Params(sessionId, List.of(A2AMessage.user(userMessage)))
        );
    }
}
