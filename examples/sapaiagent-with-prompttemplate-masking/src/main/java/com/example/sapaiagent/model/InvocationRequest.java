package com.example.sapaiagent.model;

/**
 * Request body for {@code POST /chatStream}.
 *
 * <p>Fields used per mode:
 * <ul>
 *   <li>{@link ChatMode#BASIC}                    – only {@code prompt} is used</li>
 *   <li>{@link ChatMode#PROMPT_TEMPLATE}          – {@code prompt} and {@code language} are used as template variables</li>
 *   <li>{@link ChatMode#MASKING_ANONYMIZATION}    – only {@code prompt} is used</li>
 *   <li>{@link ChatMode#MASKING_PSEUDONYMIZATION} – only {@code prompt} is used</li>
 * </ul>
 *
 * @param prompt   user input text; maps to {@code {prompt}} in the template for PROMPT_TEMPLATE mode
 * @param language target language for PROMPT_TEMPLATE mode (maps to {@code {language}} in the template, e.g. "German")
 * @param mode     which feature to demonstrate; defaults to {@link ChatMode#BASIC} when {@code null}
 */
public record InvocationRequest(String prompt, String language, ChatMode mode) {}
