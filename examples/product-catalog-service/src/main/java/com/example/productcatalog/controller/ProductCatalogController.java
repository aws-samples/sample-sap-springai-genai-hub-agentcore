/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.productcatalog.controller;

import com.example.productcatalog.model.Product;
import com.example.productcatalog.service.ProductCatalogService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

@RestController
@RequestMapping(path = "/products", produces = MediaType.APPLICATION_JSON_VALUE)
@Tag(name = "Product Catalog", description = "CRUD and search operations for the product catalog")
public class ProductCatalogController {

    private final ProductCatalogService service;

    public ProductCatalogController(ProductCatalogService service) {
        this.service = service;
    }

    @PostMapping
    @Operation(summary = "Create a new product")
    public ResponseEntity<Product> create(@RequestBody Product product) {
        return ResponseEntity.status(HttpStatus.CREATED).body(service.create(product));
    }

    @GetMapping
    @Operation(summary = "List all products")
    public List<Product> getAll() {
        return service.getAll();
    }

    @GetMapping("/{id}")
    @Operation(summary = "Get a product by ID")
    public ResponseEntity<Product> getById(@PathVariable String id) {
        return service.getById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PutMapping("/{id}")
    @Operation(summary = "Update an existing product")
    public ResponseEntity<Product> update(@PathVariable String id, @RequestBody Product product) {
        return service.update(id, product)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{id}")
    @Operation(summary = "Delete a product")
    public ResponseEntity<Void> delete(@PathVariable String id) {
        return service.delete(id) ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
    }

    @GetMapping("/search")
    @Operation(summary = "Search products by category and/or name")
    public List<Product> search(
            @RequestParam(required = false) String category,
            @RequestParam(required = false) String name) {
        if (category != null && name != null) {
            var results = new LinkedHashSet<>(service.searchByCategory(category));
            results.addAll(service.searchByName(name));
            return new ArrayList<>(results);
        }
        if (category != null) return service.searchByCategory(category);
        if (name != null) return service.searchByName(name);
        return service.getAll();
    }
}
