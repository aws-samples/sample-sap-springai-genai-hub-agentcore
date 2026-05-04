package com.example.sapaiagent.service;

import org.springframework.stereotype.Service;
import reactor.core.publisher.Flux;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.annotation.Nonnull;

@Service
public class SAPAIOrchestrationService {

    private static final Logger logger = LoggerFactory.getLogger(SAPAIOrchestrationService.class);

    private final ChainWorkflowService chainWorkflow;

    public SAPAIOrchestrationService(ChainWorkflowService chainWorkflow) {
        this.chainWorkflow = chainWorkflow;
        logger.info("SAPAIOrchestrationService initialized with ChainWorkflowService");
    }

    public Flux<String> chatStream(@Nonnull final String userPrompt, String username) {
        return Flux.just(chainWorkflow.execute(userPrompt, username));
    }
}