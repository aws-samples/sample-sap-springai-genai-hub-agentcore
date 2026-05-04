package com.example.a2a.model;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * JSON-RPC 2.0 response envelope for A2A {@code message/send}.
 */
public record A2AResponse(
        String jsonrpc,
        @JsonProperty("id") String requestId,
        Result result,
        Error error
) {
    public record Result(String content) {}
    public record Error(int code, String message) {}

    public boolean isSuccess() {
        return error == null && result != null;
    }

    public String getContent() {
        return result != null ? result.content() : null;
    }
}
