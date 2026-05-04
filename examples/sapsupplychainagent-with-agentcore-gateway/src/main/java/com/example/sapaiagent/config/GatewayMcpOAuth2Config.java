/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.WebClient;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Instant;
import java.util.Base64;

/**
 * Configures the MCP WebClient with OAuth2 client_credentials flow so that
 * requests to the AgentCore Gateway include a Bearer JWT token.
 */
@Configuration
public class GatewayMcpOAuth2Config {

    @Value("${spring.security.oauth2.client.registration.gateway.client-id:}")
    private String clientId;

    @Value("${spring.security.oauth2.client.registration.gateway.client-secret:}")
    private String clientSecret;

    @Value("${spring.security.oauth2.client.provider.gateway.token-uri:}")
    private String tokenUri;

    @Value("${spring.security.oauth2.client.registration.gateway.scope:}")
    private String scope;

    private String cachedToken;
    private Instant tokenExpiry = Instant.MIN;

    @Bean
    WebClient.Builder mcpWebClientBuilder() {
        return WebClient.builder()
                .filter((request, next) -> {
                    if (clientId.isEmpty() || tokenUri.isEmpty()) {
                        return next.exchange(request);
                    }
                    String host = request.url().getHost();
                    if (host == null || !host.contains("gateway.bedrock-agentcore")) {
                        return next.exchange(request);
                    }
                    String token = getAccessToken();
                    ClientRequest authed = ClientRequest.from(request)
                            .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                            .build();
                    return next.exchange(authed);
                });
    }

    private synchronized String getAccessToken() {
        if (cachedToken != null && Instant.now().isBefore(tokenExpiry)) {
            return cachedToken;
        }

        try {
            String credentials = Base64.getEncoder()
                    .encodeToString((clientId + ":" + clientSecret).getBytes());

            String body = "grant_type=client_credentials&scope=" + scope;

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(tokenUri))
                    .header("Content-Type", MediaType.APPLICATION_FORM_URLENCODED_VALUE)
                    .header("Authorization", "Basic " + credentials)
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();

            HttpResponse<String> response = HttpClient.newHttpClient()
                    .send(request, HttpResponse.BodyHandlers.ofString());

            // Parse access_token and expires_in from JSON response
            String responseBody = response.body();
            String token = extractJsonField(responseBody, "access_token");
            int expiresIn = Integer.parseInt(extractJsonField(responseBody, "expires_in"));

            cachedToken = token;
            tokenExpiry = Instant.now().plusSeconds(expiresIn - 60); // refresh 60s early
            return cachedToken;
        } catch (Exception e) {
            throw new RuntimeException("Failed to fetch gateway OAuth2 token", e);
        }
    }

    private static String extractJsonField(String json, String field) {
        // Simple extraction — avoids adding a JSON dependency for two fields
        String key = "\"" + field + "\":";
        int idx = json.indexOf(key);
        if (idx < 0) throw new IllegalArgumentException("Field not found: " + field);
        int start = idx + key.length();
        // Skip whitespace
        while (start < json.length() && json.charAt(start) == ' ') start++;
        if (json.charAt(start) == '"') {
            int end = json.indexOf('"', start + 1);
            return json.substring(start + 1, end);
        } else {
            int end = start;
            while (end < json.length() && json.charAt(end) != ',' && json.charAt(end) != '}') end++;
            return json.substring(start, end).trim();
        }
    }
}
