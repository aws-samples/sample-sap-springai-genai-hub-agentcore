package com.example.mcptools;

import com.example.a2a.controller.A2AServerController;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;

@SpringBootApplication
@Import(A2AServerController.class)
public class McpToolsAgentApplication {

    public static void main(String[] args) {
        SpringApplication.run(McpToolsAgentApplication.class, args);
    }
}
