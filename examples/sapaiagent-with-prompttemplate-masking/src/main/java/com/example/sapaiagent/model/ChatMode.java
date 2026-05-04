package com.example.sapaiagent.model;

/**
 * Selects which orchestration feature the /chatStream endpoint demonstrates.
 *
 * <ul>
 *   <li>{@link #BASIC}                    – plain streaming chat, no additional configuration</li>
 *   <li>{@link #PROMPT_TEMPLATE}          – Spring AI client-side prompt templating ({@code {variable}} substitution)</li>
 *   <li>{@link #MASKING_ANONYMIZATION}    – DPI masking: PII replaced with generic tokens (e.g. {@code MASKED_EMAIL}) before the LLM sees the prompt; one-way, permanent</li>
 *   <li>{@link #MASKING_PSEUDONYMIZATION} – DPI masking: PII replaced with numbered tokens (e.g. {@code MASKED_PERSON_1}) before the LLM, then reversed back in the final response; two-way</li>
 * </ul>
 */
public enum ChatMode {
    BASIC,
    PROMPT_TEMPLATE,
    MASKING_ANONYMIZATION,
    MASKING_PSEUDONYMIZATION
}
