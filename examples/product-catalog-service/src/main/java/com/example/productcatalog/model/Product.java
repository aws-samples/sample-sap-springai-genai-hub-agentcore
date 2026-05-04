package com.example.productcatalog.model;

public record Product(String id, String name, String description,
                      double price, String category, int stockQuantity, String sku) {}
