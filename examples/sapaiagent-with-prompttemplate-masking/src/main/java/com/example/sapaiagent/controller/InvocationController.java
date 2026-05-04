package com.example.sapaiagent.controller;

import com.example.sapaiagent.model.InvocationRequest;
import com.example.sapaiagent.service.SAPAIOrchestrationService;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Flux;

@RestController
public class InvocationController {

    private final SAPAIOrchestrationService chatService;

    public InvocationController(SAPAIOrchestrationService chatService) {
        this.chatService = chatService;
    }

    /**
     * Single streaming endpoint that routes to different SAP AI SDK orchestration
     * features based on the {@code mode} field in the request body.
     *
     * <pre>
     * POST /chatStream
     *
     * Basic chat (default):
     *   {"prompt": "Tell me about Spring AI"}
     *
     * Prompt templating — responds in the specified language:
     *   {"prompt": "What is the capital of Germany?", "language": "French", "mode": "PROMPT_TEMPLATE"}
     *
     * DPI masking — anonymization (PII replaced with generic tokens):
     *   {"prompt": "Feedback from John Smith (john@example.com): great service!", "mode": "MASKING_ANONYMIZATION"}
     *
     * DPI masking — pseudonymization (PII replaced with consistent pseudonyms):
     *   {"prompt": "Alice (alice@example.com) and Bob (bob@example.com) both reported the same issue.", "mode": "MASKING_PSEUDONYMIZATION"}
     * </pre>
     */
    @PostMapping(value = "chatStream", produces = MediaType.TEXT_PLAIN_VALUE)
    public Flux<String> handleChatStream(@RequestBody InvocationRequest request) {
        return chatService.chatStream(request);
    }
}
