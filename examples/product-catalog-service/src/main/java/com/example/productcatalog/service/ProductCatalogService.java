/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.productcatalog.service;

import com.example.productcatalog.model.Product;
import jakarta.annotation.PostConstruct;
import org.springframework.stereotype.Service;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class ProductCatalogService {

    private final Map<String, Product> products = new ConcurrentHashMap<>();

    @PostConstruct
    void seed() {
        create(new Product(null, "Industrial Sensor", "High-precision industrial temperature and humidity sensor for manufacturing environments", 249.99, "Electronics", 150, "IND-SENS-001"));
        create(new Product(null, "Servo Motor", "12V DC servo motor with 180-degree rotation for robotic applications", 189.50, "Motors", 75, "SRV-MOT-002"));
        create(new Product(null, "Power Cable 10m", "Heavy-duty 10-meter power cable rated for industrial machinery", 34.99, "Cables", 500, "PWR-CBL-003"));
        create(new Product(null, "Hydraulic Pump", "Variable displacement hydraulic pump for heavy equipment", 1299.00, "Hydraulics", 20, "HYD-PMP-004"));
        create(new Product(null, "Safety Helmet", "Industrial safety helmet with adjustable suspension and chin strap", 45.00, "Safety", 300, "SAF-HLM-005"));
    }

    public Product create(Product product) {
        String id = UUID.randomUUID().toString();
        var created = new Product(id, product.name(), product.description(),
                product.price(), product.category(), product.stockQuantity(), product.sku());
        products.put(id, created);
        return created;
    }

    public Optional<Product> getById(String id) {
        return Optional.ofNullable(products.get(id));
    }

    public List<Product> getAll() {
        return List.copyOf(products.values());
    }

    public Optional<Product> update(String id, Product product) {
        if (!products.containsKey(id)) return Optional.empty();
        var updated = new Product(id, product.name(), product.description(),
                product.price(), product.category(), product.stockQuantity(), product.sku());
        products.put(id, updated);
        return Optional.of(updated);
    }

    public boolean delete(String id) {
        return products.remove(id) != null;
    }

    public List<Product> searchByCategory(String category) {
        return products.values().stream()
                .filter(p -> p.category().equalsIgnoreCase(category))
                .toList();
    }

    public List<Product> searchByName(String name) {
        String lower = name.toLowerCase();
        return products.values().stream()
                .filter(p -> p.name().toLowerCase().contains(lower))
                .toList();
    }
}
