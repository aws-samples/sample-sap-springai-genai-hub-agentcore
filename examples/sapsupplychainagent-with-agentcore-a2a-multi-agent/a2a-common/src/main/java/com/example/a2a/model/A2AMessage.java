package com.example.a2a.model;

/**
 * A2A message — part of a {@code message/send} JSON-RPC params.
 */
public record A2AMessage(
        String role,
        String content
) {
    public static A2AMessage user(String content) {
        return new A2AMessage("user", content);
    }
}
