/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapquery.service;

import com.example.sapquery.model.SAPOdataAPISpec;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.List;

@Component
public class SAPOdataApiSelectorTool {

    private static final Logger logger = LoggerFactory.getLogger(SAPOdataApiSelectorTool.class);
    private final String catalog;

    public SAPOdataApiSelectorTool(SAPOdataApiSpecLoader specLoader) {
        var specs = specLoader.loadSpecs("classpath:openapispecs");
        this.catalog = buildCatalog(specs);
        logger.info("SAPOdataApiSelectorTool initialized with {} specs", specs.size());
    }

    private static String buildCatalog(List<SAPOdataAPISpec> specs) {
        var sb = new StringBuilder();
        for (var spec : specs) {
            String sandboxUrl = spec.baseUrls().stream()
                    .map(SAPOdataAPISpec.BaseUrl::url)
                    .filter(u -> u.contains("sandbox.api.sap.com"))
                    .findFirst()
                    .orElse(spec.baseUrls().isEmpty() ? "" : spec.baseUrls().get(0).url());

            sb.append(String.format("\nAPI: %s\nDescription: %s\nbaseUrl: %s\nGET endpoints:\n",
                    spec.title(),
                    spec.description().substring(0, Math.min(200, spec.description().length())),
                    sandboxUrl));

            for (String path : spec.paths()) {
                sb.append("  - ").append(path).append("\n");
            }
        }
        return sb.toString();
    }

    @Tool(description = """
        Select the appropriate SAP API and specific GET endpoint for the user's requirement.
        Returns a catalog of available APIs with all their GET endpoints.
        Use ONLY for SAP supply chain queries (freight, inventory, warehouse stock).
        The LLM should pick the most specific endpoint matching the user's need and return
        JSON with: apiTitle, baseUrl, endpoint, httpMethod, reasoning.
        """)
    public String selectApi(
            @ToolParam(description = "User's SAP business requirement") String requirement) {

        logger.info("=== TOOL CALL: selectApi === Requirement: {}", requirement);

        String result = String.format("""
            User requirement: %s

            Available SAP APIs and their GET endpoints:
            %s

            Instructions:
            1. Pick the API and specific GET endpoint that best matches the user's requirement.
            2. Return JSON with: apiTitle, baseUrl, endpoint (just the path like /FreightBookingCharge), httpMethod (GET), reasoning (why this endpoint was chosen).
            """, requirement, catalog);
        logger.info("=== TOOL SUCCESS: selectApi === Catalog size: {} chars", result.length());
        return result;
    }
}
