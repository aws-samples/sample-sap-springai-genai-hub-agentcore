/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sap.cloud.sdk.cloudplatform.connectivity.DefaultHttpDestination;
import com.sap.cloud.sdk.cloudplatform.connectivity.Header;
import com.sap.cloud.sdk.services.openapi.apiclient.ApiClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;

import java.util.List;

@Component
public class SAPApiExecutorTool {

    private static final Logger logger = LoggerFactory.getLogger(SAPApiExecutorTool.class);
    private static final int MAX_RESPONSE_CHARS = 4000;
    private static final ObjectMapper objectMapper = new ObjectMapper();
    private final String apiKey;

    public SAPApiExecutorTool() {
        this.apiKey = System.getenv("SAP_S4HANA_PUBLIC_CLOUD_KEY");
        if (apiKey == null || apiKey.isEmpty()) {
            logger.warn("SAP_S4HANA_PUBLIC_CLOUD_KEY environment variable not set");
        }
    }

    @Tool(description = """
        Execute a GET request to an SAP API. Returns a truncated JSON response (max 4000 chars)
        to keep LLM processing fast. Use with apiTitle, baseUrl, and endpoint from selectApi.
        """)
    public String executeApi(
            @ToolParam(description = "API title") String apiTitle,
            @ToolParam(description = "Base URL of the API") String baseUrl,
            @ToolParam(description = "Endpoint path") String endpoint) {

        logger.info("=== TOOL CALL: executeApi === API: {}, URL: {}{}", apiTitle, baseUrl, endpoint);

        try {
            var destination = DefaultHttpDestination.builder(baseUrl)
                    .header(new Header("APIKey", apiKey))
                    .header(new Header("DataServiceVersion", "2.0"))
                    .header(new Header("Accept", "application/json"))
                    .build();

            ApiClient apiClient = new ApiClient(destination);
            apiClient.setBasePath(baseUrl);

            MultiValueMap<String, String> queryParams = new LinkedMultiValueMap<>();
            HttpHeaders headerParams = new HttpHeaders();
            MultiValueMap<String, Object> formParams = new LinkedMultiValueMap<>();
            ParameterizedTypeReference<String> returnType = new ParameterizedTypeReference<>() {};

            long start = System.currentTimeMillis();
            String response = apiClient.invokeAPI(
                    endpoint,
                    HttpMethod.GET,
                    queryParams, null, headerParams, formParams,
                    List.of(MediaType.APPLICATION_JSON),
                    MediaType.APPLICATION_JSON,
                    new String[0], returnType);

            logger.info("=== TOOL SUCCESS: executeApi === {} completed in {}ms, response length: {}",
                    apiTitle, System.currentTimeMillis() - start, response != null ? response.length() : 0);

            return truncateResponse(apiTitle, response);

        } catch (Exception e) {
            logger.error("=== TOOL FAILED: executeApi === API: {}, Error: {}", apiTitle, e.getMessage());
            return "Error executing API: " + e.getMessage();
        }
    }

    private String truncateResponse(String apiTitle, String response) {
        if (response == null) return apiTitle + " API returned no data.";
        if (response.length() <= MAX_RESPONSE_CHARS) return apiTitle + " API Response:\n" + response;

        try {
            JsonNode root = objectMapper.readTree(response);
            JsonNode valueNode = root.path("value");
            if (valueNode.isArray() && valueNode.size() > 0) {
                int totalRecords = valueNode.size();
                var sb = new StringBuilder();
                sb.append(String.format("%s API Response (showing first records of %d total):\n{\"value\":[\n", apiTitle, totalRecords));
                int count = 0;
                for (JsonNode item : valueNode) {
                    String itemStr = objectMapper.writeValueAsString(item);
                    if (sb.length() + itemStr.length() + 10 > MAX_RESPONSE_CHARS) break;
                    if (count > 0) sb.append(",\n");
                    sb.append(itemStr);
                    count++;
                }
                sb.append("\n]}");
                return sb.toString();
            }
        } catch (Exception e) {
            logger.debug("Could not parse response as JSON for smart truncation, using simple truncation");
        }

        return String.format("%s API Response (truncated, full response was %d chars):\n%s",
                apiTitle, response.length(), response.substring(0, MAX_RESPONSE_CHARS));
    }
}
