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

    @PostMapping(value = "invocations", produces = MediaType.TEXT_PLAIN_VALUE)
    public Flux<String> handleInvocation(
            @RequestBody InvocationRequest request,
            @RequestHeader(value = "Authorization", required = false) String auth) {
        String username = auth != null ? auth : "default";
        return chatService.chatStream(request.prompt(), username);
    }
}
