package com.example.sapquery.model;

import java.util.List;

public record SAPOdataAPISpec(
        String file,
        String title,
        String description,
        List<String> paths,
        List<BaseUrl> baseUrls)
{
    public record BaseUrl(String url, String description) {}
}
