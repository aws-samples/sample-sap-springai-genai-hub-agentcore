package com.example.sapaiagent.service;

import org.springframework.stereotype.Service;
import reactor.core.publisher.Flux;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Service
public class SAPAIOrchestrationService {

    private static final Logger logger = LoggerFactory.getLogger(SAPAIOrchestrationService.class);

    private final ChainWorkflowService chainWorkflow;

    public SAPAIOrchestrationService(ChainWorkflowService chainWorkflow) {
        this.chainWorkflow = chainWorkflow;
        logger.info("SAPAIOrchestrationService initialized with ChainWorkflowService");
    }

    public Flux<String> chatStream(String request, String username, String sessionId) {
        logger.info("==== Inside AgentCore Runtime Invocation ====");
        return Flux.just(chainWorkflow.execute(request, username, sessionId));
    }
}