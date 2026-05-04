/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapquery.service;

import com.example.sapquery.model.SAPOdataAPISpec;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

@Service
public class SAPOdataApiSpecLoader {

    private static final Logger logger = LoggerFactory.getLogger(SAPOdataApiSpecLoader.class);
    private final ObjectMapper objectMapper = new ObjectMapper();
    private final PathMatchingResourcePatternResolver resolver = new PathMatchingResourcePatternResolver();

    public List<SAPOdataAPISpec> loadSpecs(String location) {
        List<SAPOdataAPISpec> specs = new ArrayList<>();
        try {
            Resource[] resources = resolver.getResources(location + "/*.json");
            for (Resource resource : resources) {
                try {
                    specs.add(parseSpec(resource.getFilename(), objectMapper.readTree(resource.getInputStream())));
                } catch (IOException e) {
                    logger.warn("Error parsing {}: {}", resource.getFilename(), e.getMessage());
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("Failed to load OpenAPI specs from " + location, e);
        }
        logger.info("Loaded {} API specs from {}", specs.size(), location);
        return specs;
    }

    private SAPOdataAPISpec parseSpec(String fileName, JsonNode root) {
        JsonNode info = root.path("info");
        String title = info.path("title").asText();
        String description = info.path("description").asText();

        List<SAPOdataAPISpec.BaseUrl> baseUrls = new ArrayList<>();
        JsonNode servers = root.path("servers");
        if (servers.isArray()) {
            servers.forEach(server -> {
                String url = server.path("url").asText();
                if (!url.isEmpty()) {
                    baseUrls.add(new SAPOdataAPISpec.BaseUrl(url, server.path("description").asText("")));
                }
            });
        }
        if (baseUrls.isEmpty()) {
            baseUrls.add(new SAPOdataAPISpec.BaseUrl("/", "Default"));
        }

        List<String> paths = new ArrayList<>();
        JsonNode pathsNode = root.path("paths");
        pathsNode.fieldNames().forEachRemaining(path -> {
            if (path.contains("{") || path.equals("/$batch")) return;
            JsonNode pathObj = pathsNode.path(path);
            if (pathObj.has("get")) {
                String summary = pathObj.path("get").path("summary").asText("");
                paths.add(summary.isEmpty() ? path : path + " (" + summary + ")");
            }
        });

        logger.debug("Parsed spec '{}': {} GET endpoints", title, paths.size());
        return new SAPOdataAPISpec(fileName, title, description, paths, baseUrls);
    }
}
