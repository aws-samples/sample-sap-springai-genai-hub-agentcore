package com.example.orchestrator.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * Configuration properties for remote A2A agent URLs.
 * Bound from {@code a2a.agents.*} in application.properties.
 *
 * Example:
 *   a2a.agents.sap-query-agent.url=http://localhost:9091
 *   a2a.agents.sap-execute-format-agent.url=http://localhost:9092
 */
@Component
@ConfigurationProperties(prefix = "a2a")
public class A2AAgentsConfig {

    private Map<String, AgentConfig> agents = new java.util.LinkedHashMap<>();

    public Map<String, AgentConfig> getAgents() {
        return agents;
    }

    public void setAgents(Map<String, AgentConfig> agents) {
        this.agents = agents;
    }

    public static class AgentConfig {
        private String url;

        public String getUrl() {
            return url;
        }

        public void setUrl(String url) {
            this.url = url;
        }
    }
}
