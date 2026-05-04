package com.example.a2a;

import com.example.a2a.model.AgentCard;

/**
 * Contract that every A2A worker agent must implement.
 * The {@code A2AServerController} delegates all requests to the single bean
 * implementing this interface in the application context.
 */
public interface AgentExecutor {

    /** Returns this agent's identity and capabilities for A2A discovery. */
    AgentCard getAgentCard();

    /**
     * Executes the agent's core logic for the given user message.
     *
     * @param userMessage  the incoming prompt from the orchestrator
     * @param sessionId    conversation/session identifier for memory isolation
     * @return the agent's text response
     */
    String execute(String userMessage, String sessionId);
}
