/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.service;

import com.example.sapaiagent.model.ChatMode;
import com.example.sapaiagent.model.InvocationRequest;
import com.sap.ai.sdk.orchestration.DpiMasking;
import com.sap.ai.sdk.orchestration.OrchestrationAiModel;
import com.sap.ai.sdk.orchestration.OrchestrationModuleConfig;
import com.sap.ai.sdk.orchestration.model.DPIEntities;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatModel;
import com.sap.ai.sdk.orchestration.spring.OrchestrationChatOptions;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.chat.prompt.PromptTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Flux;

import javax.annotation.Nonnull;
import java.util.Map;
import java.util.Objects;

@Service
public class SAPAIOrchestrationService {

    private final OrchestrationChatModel chatModel;
    private final OrchestrationChatOptions chatOptions;
    private final ChatClient chatClient;

    /**
     * The customer support prompt template is loaded from
     * {@code src/main/resources/prompttemplates/customer-support-prompt-template.txt}.
     * <p>
     * Externalising the template as a classpath resource means it can be updated
     * without touching Java code, and different environments can supply different
     * template files — a key benefit of Spring AI's {@link PromptTemplate}.
     */
    @Value("classpath:/prompttemplates/customer-support-prompt-template.txt")
    private Resource customerSupportTemplate;

    public SAPAIOrchestrationService() {
        this.chatModel = new OrchestrationChatModel();
        this.chatOptions = new OrchestrationChatOptions(
                new OrchestrationModuleConfig().withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET));
        this.chatClient = ChatClient.builder(this.chatModel).build();
    }

    /**
     * Routes the streaming request to the appropriate feature implementation
     * based on {@link InvocationRequest#mode()}.
     */
    public Flux<String> chatStream(@Nonnull final InvocationRequest request) {
        return switch (Objects.requireNonNullElse(request.mode(), ChatMode.BASIC)) {
            case PROMPT_TEMPLATE          -> streamWithPromptTemplate(request.prompt(), request.language());
            case MASKING_ANONYMIZATION    -> streamWithMaskingAnonymization(request.prompt());
            case MASKING_PSEUDONYMIZATION -> streamWithMaskingPseudonymization(request.prompt());
            case BASIC                    -> streamBasic(request.prompt());
        };
    }

    /**
     * Basic streaming chat — no additional orchestration configuration.
     */
    private Flux<String> streamBasic(@Nonnull final String userPrompt) {
        Prompt prompt = new Prompt(userPrompt, chatOptions);
        return chatClient.prompt(prompt).stream().chatResponse()
                .mapNotNull(r -> r.getResult().getOutput().getText());
    }

    /**
     * Demonstrates Spring AI {@link PromptTemplate} using a structured customer support template.
     *
     * <p>The template is loaded from {@code classpath:/prompttemplates/customer-support-prompt-template.txt} and
     * contains two placeholders:
     * <ul>
     *   <li>{@code {prompt}}   — the customer's question or complaint</li>
     *   <li>{@code {language}} — the language in which the response should be written</li>
     * </ul>
     *
     * <p>At runtime, {@link PromptTemplate#create(Map, org.springframework.ai.chat.model.ChatOptions)}
     * substitutes the variables and produces a fully-formed {@link Prompt} that is sent to the LLM.
     * The template structure (tone, response format, escalation instruction) stays consistent
     * across all calls — only the variable values change per request.
     *
     * <p>Example request:
     * <pre>{@code
     * {
     *   "prompt": "I cannot log into my account after resetting my password.",
     *   "language": "German",
     *   "mode": "PROMPT_TEMPLATE"
     * }
     * }</pre>
     *
     * <p>The rendered prompt sent to the LLM will contain the full template text with
     * {@code {prompt}} and {@code {language}} replaced by the values above.
     */
    private Flux<String> streamWithPromptTemplate(final String userPrompt, final String language) {
        String targetPrompt   = Objects.requireNonNullElse(userPrompt, "I need help with my account.");
        String targetLanguage = Objects.requireNonNullElse(language, "English");

        PromptTemplate promptTemplate = new PromptTemplate(customerSupportTemplate);
        Prompt prompt = promptTemplate.create(
                Map.of("prompt", targetPrompt, "language", targetLanguage),
                chatOptions);

        return chatClient.prompt(prompt).stream().chatResponse()
                .mapNotNull(r -> r.getResult().getOutput().getText());
    }

    /**
     * Demonstrates SAP AI SDK DPI masking — <strong>anonymization</strong> mode.
     * <p>
     * Before the prompt is sent to the LLM, SAP AI Core scans it for PII and replaces
     * each detected entity with a generic token (e.g. {@code john.doe@example.com} →
     * {@code MASKED_EMAIL}). The LLM never sees the real data, and the tokens are
     * <em>not</em> reversed in the response — the anonymization is permanent.
     * All instances of the same entity type receive the <em>same</em> token, so the
     * LLM cannot distinguish between two different people or email addresses.
     * <p>
     * This example masks: {@link DPIEntities#EMAIL}, {@link DPIEntities#PERSON},
     * {@link DPIEntities#PHONE}, and {@link DPIEntities#ADDRESS}.
     * <p>
     * Example request:
     * <pre>{@code
     * {
     *   "prompt": "Evaluate this feedback from John Smith (john.smith@example.com, +1-555-0100, 42 Oak Street): The service was excellent!",
     *   "mode": "MASKING_ANONYMIZATION"
     * }
     * }</pre>
     */
    private Flux<String> streamWithMaskingAnonymization(@Nonnull final String userPrompt) {
        DpiMasking masking = DpiMasking.anonymization()
                .withEntities(DPIEntities.EMAIL, DPIEntities.PERSON, DPIEntities.PHONE, DPIEntities.ADDRESS);

        OrchestrationChatOptions maskedOptions = new OrchestrationChatOptions(
                new OrchestrationModuleConfig()
                        .withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET)
                        .withMaskingConfig(masking));

        Prompt prompt = new Prompt(userPrompt, maskedOptions);
        return chatClient.prompt(prompt).stream().chatResponse()
                .mapNotNull(r -> r.getResult().getOutput().getText());
    }

    /**
     * Demonstrates SAP AI SDK DPI masking — <strong>pseudonymization</strong> mode.
     * <p>
     * Before the prompt is sent to the LLM, SAP AI Core replaces each detected PII entity
     * with a <em>numbered pseudonym</em> (e.g. {@code Alice} → {@code MASKED_PERSON_1},
     * {@code alice@example.com} → {@code MASKED_EMAIL_1}, {@code Bob} → {@code MASKED_PERSON_2}).
     * The same entity always gets the same pseudonym within a request, so the LLM can
     * reason about relationships between entities without seeing real personal data.
     * After the LLM responds, SAP AI Core <em>reverses</em> the mapping — replacing
     * {@code MASKED_PERSON_1} back to {@code Alice} in the final response.
     * The original values appearing in the output confirms the two-way masking worked.
     * <p>
     * This example masks: {@link DPIEntities#PERSON} and {@link DPIEntities#EMAIL}.
     * <p>
     * Example request:
     * <pre>{@code
     * {
     *   "prompt": "Username: Alice\nEmail: alice@example.com\nFeedback: The product is great but the onboarding needs improvement. My colleague Bob (bob@example.com) agrees.",
     *   "mode": "MASKING_PSEUDONYMIZATION"
     * }
     * }</pre>
     */
    private Flux<String> streamWithMaskingPseudonymization(@Nonnull final String userPrompt) {
        DpiMasking masking = DpiMasking.pseudonymization()
                .withEntities(DPIEntities.PERSON, DPIEntities.EMAIL);

        OrchestrationChatOptions maskedOptions = new OrchestrationChatOptions(
                new OrchestrationModuleConfig()
                        .withLlmConfig(OrchestrationAiModel.CLAUDE_4_5_SONNET)
                        .withMaskingConfig(masking));

        Prompt prompt = new Prompt(userPrompt, maskedOptions);
        return chatClient.prompt(prompt).stream().chatResponse()
                .mapNotNull(r -> r.getResult().getOutput().getText());
    }
}
