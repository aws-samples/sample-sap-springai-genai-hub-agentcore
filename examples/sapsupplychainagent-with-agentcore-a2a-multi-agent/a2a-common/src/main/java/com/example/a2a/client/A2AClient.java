/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.a2a.client;

import com.example.a2a.model.A2ARequest;
import com.example.a2a.model.A2AResponse;
import com.example.a2a.model.AgentCard;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.http.ContentStreamProvider;
import software.amazon.awssdk.http.SdkHttpMethod;
import software.amazon.awssdk.http.SdkHttpRequest;
import software.amazon.awssdk.http.auth.aws.signer.AwsV4HttpSigner;
import software.amazon.awssdk.http.auth.spi.signer.SignRequest;
import software.amazon.awssdk.http.auth.spi.signer.SignedRequest;
import software.amazon.awssdk.identity.spi.AwsCredentialsIdentity;
import software.amazon.awssdk.regions.Region;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * HTTP client for calling remote A2A agents deployed on AgentCore.
 *
 * All requests are signed with SigV4 using the container's IAM execution role
 * credentials (via {@link DefaultCredentialsProvider}). This is required because
 * AgentCore's InvokeAgentRuntime API enforces SigV4 authentication.
 *
 * Handles:
 *   - Agent card discovery:  GET  {baseUrl}/.well-known/agent-card.json
 *   - Message invocation:    POST {baseUrl}/ with JSON-RPC 2.0 body
 */
public class A2AClient {

    private static final Logger log = LoggerFactory.getLogger(A2AClient.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int READ_TIMEOUT_MS    = 120_000;
    private static final String SERVICE_NAME = "bedrock-agentcore";

    private final String baseUrl;
    private final String agentName;
    private final Region region;
    private final DefaultCredentialsProvider credentialsProvider;
    private final AwsV4HttpSigner signer;

    public A2AClient(String baseUrl) {
        this(baseUrl, baseUrl);
    }

    public A2AClient(String baseUrl, String agentName) {
        this.baseUrl = baseUrl;
        this.agentName = agentName;
        String regionStr = System.getenv("AWS_REGION");
        if (regionStr == null || regionStr.isBlank()) {
            regionStr = extractRegionFromUrl(baseUrl);
        }
        this.region = Region.of(regionStr);
        this.credentialsProvider = DefaultCredentialsProvider.builder().build();
        this.signer = AwsV4HttpSigner.create();
    }

    /** Fetches the remote agent's AgentCard for capability discovery. */
    public AgentCard fetchAgentCard() {
        log.info("Fetching agent card from {}", baseUrl);
        String url = buildSubpathUrl("/.well-known/agent-card.json");
        String responseBody = executeSignedRequest("GET", url, null);
        try {
            return MAPPER.readValue(responseBody, AgentCard.class);
        } catch (Exception e) {
            throw new RuntimeException("Failed to parse agent card from " + baseUrl, e);
        }
    }

    /** Sends a user message to the remote agent and returns its text response. */
    public String sendMessage(String userMessage, String sessionId) {
        log.info("Sending A2A message to {} ({}): sessionId={}, message={}",
                agentName, baseUrl, sessionId,
                userMessage.substring(0, Math.min(100, userMessage.length())));

        // Tag the current OTEL span with agent identity for trace visibility
        try {
            var span = io.opentelemetry.api.trace.Span.current();
            span.setAttribute("peer.service", agentName);
            span.setAttribute("a2a.agent.name", agentName);
            span.setAttribute("session.id", sessionId);
        } catch (Throwable ignored) { }

        var request = A2ARequest.messageSend(sessionId, userMessage);
        String body;
        try {
            body = MAPPER.writeValueAsString(request);
        } catch (Exception e) {
            throw new RuntimeException("Failed to serialize A2A request", e);
        }

        String url = buildSubpathUrl("/");
        String responseBody = executeSignedRequest("POST", url, body);

        A2AResponse response;
        try {
            response = MAPPER.readValue(responseBody, A2AResponse.class);
        } catch (Exception e) {
            throw new RuntimeException("Failed to parse A2A response from " + baseUrl +
                    ": " + responseBody, e);
        }

        if (response == null) {
            throw new RuntimeException("Null response from agent at " + baseUrl);
        }
        if (!response.isSuccess()) {
            var err = response.error();
            throw new RuntimeException("A2A error from " + baseUrl + ": " +
                    (err != null ? err.message() : "unknown error"));
        }

        String content = response.getContent();
        log.info("A2A response from {} ({}): length={}", agentName, baseUrl,
                content != null ? content.length() : 0);
        return content;
    }

    /**
     * Builds a URL by inserting a subpath before the query string.
     * e.g., baseUrl = "https://host/runtimes/arn/invocations?qualifier=DEFAULT"
     *        subpath = "/.well-known/agent-card.json"
     *        result  = "https://host/runtimes/arn/invocations/.well-known/agent-card.json?qualifier=DEFAULT"
     */
    private String buildSubpathUrl(String subpath) {
        int queryIdx = baseUrl.indexOf('?');
        if (queryIdx == -1) {
            // No query string — simple append
            String base = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
            return base + subpath;
        }
        String pathPart = baseUrl.substring(0, queryIdx);
        String queryPart = baseUrl.substring(queryIdx);
        if (pathPart.endsWith("/")) {
            pathPart = pathPart.substring(0, pathPart.length() - 1);
        }
        return pathPart + subpath + queryPart;
    }

    /** Executes a SigV4-signed HTTP request to an AgentCore endpoint. */
    private String executeSignedRequest(String method, String url, String body) {
        try {
            URI uri = URI.create(url);
            AwsCredentialsIdentity credentials = credentialsProvider.resolveIdentity().join();

            // Build the SDK HTTP request
            SdkHttpRequest.Builder httpBuilder = SdkHttpRequest.builder()
                    .uri(uri)
                    .method(SdkHttpMethod.fromValue(method))
                    .putHeader("Content-Type", "application/json")
                    .putHeader("Accept", "application/json");

            SdkHttpRequest httpRequest = httpBuilder.build();

            // Build sign request
            SignRequest.Builder<AwsCredentialsIdentity> signBuilder = SignRequest.builder(credentials)
                    .request(httpRequest)
                    .putProperty(AwsV4HttpSigner.SERVICE_SIGNING_NAME, SERVICE_NAME)
                    .putProperty(AwsV4HttpSigner.REGION_NAME, region.id());

            if (body != null) {
                signBuilder.payload(ContentStreamProvider.fromUtf8String(body));
            }

            SignedRequest signedRequest = signer.sign(signBuilder.build());
            SdkHttpRequest signed = signedRequest.request();

            // Execute via HttpURLConnection
            HttpURLConnection conn = (HttpURLConnection) uri.toURL().openConnection();
            conn.setRequestMethod(method);
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);

            // Copy all signed headers
            for (Map.Entry<String, List<String>> header : signed.headers().entrySet()) {
                for (String value : header.getValue()) {
                    conn.setRequestProperty(header.getKey(), value);
                }
            }

            if (body != null) {
                conn.setDoOutput(true);
                conn.getOutputStream().write(body.getBytes(StandardCharsets.UTF_8));
                conn.getOutputStream().flush();
            }

            int status = conn.getResponseCode();
            InputStream is = (status >= 200 && status < 300)
                    ? conn.getInputStream() : conn.getErrorStream();
            String responseBody = new String(is.readAllBytes(), StandardCharsets.UTF_8);

            if (status < 200 || status >= 300) {
                throw new RuntimeException(status + " " + conn.getResponseMessage() +
                        ": " + responseBody);
            }

            return responseBody;
        } catch (RuntimeException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException("SigV4 request to " + url + " failed: " + e.getMessage(), e);
        }
    }

    private static String extractRegionFromUrl(String url) {
        try {
            String host = URI.create(url).getHost();
            String[] parts = host.split("\\.");
            if (parts.length >= 3) return parts[1];
        } catch (Exception ignored) { }
        return "us-east-1";
    }
}
