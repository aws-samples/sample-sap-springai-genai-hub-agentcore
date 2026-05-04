package com.example.a2a.model;

import java.util.List;

/**
 * A skill that an A2A agent exposes — maps to a JSON-RPC tool the orchestrator
 * can register as a {@code RemoteAgentToolCallback}.
 */
public record AgentSkill(
        String id,
        String name,
        String description,
        List<String> tags,
        List<String> examples
) {}
