package com.example.a2a.model;

import java.util.List;

/**
 * Agent Card per A2A spec — served at {@code GET /.well-known/agent-card.json}.
 * Describes the agent's identity, capabilities, and A2A endpoint.
 */
public record AgentCard(
        String name,
        String description,
        String url,
        String version,
        List<AgentSkill> skills
) {}
