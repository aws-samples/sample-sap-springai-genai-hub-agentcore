/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */
package com.example.sapaiagent.config;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.stereotype.Component;

import java.lang.reflect.Method;
import java.util.Arrays;

/**
 * AOP aspect that automatically wraps every {@link Tool @Tool}-annotated method
 * in an OTEL span with GenAI semantic convention attributes.
 *
 * Produces spans like:
 *   execute_tool selectApi
 *   execute_tool executeApi
 *   execute_tool getWeather
 *   execute_tool getCurrentDateTime
 *
 * With attributes: gen_ai.system, gen_ai.operation.name, gen_ai.tool.name, gen_ai.tool.call.id
 */
@Aspect
@Component
public class ToolSpanAspect {

    public static final String GEN_AI_SYSTEM = "sap.aws.bedrock";

    private final Tracer tracer;

    public ToolSpanAspect(Tracer tracer) {
        this.tracer = tracer;
    }

    @Around("@annotation(org.springframework.ai.tool.annotation.Tool)")
    public Object traceToolCall(ProceedingJoinPoint joinPoint) throws Throwable {
        String methodName = joinPoint.getSignature().getName();

        Span span = tracer.spanBuilder("execute_tool " + methodName)
                .setAttribute("gen_ai.system", GEN_AI_SYSTEM)
                .setAttribute("gen_ai.operation.name", "execute_tool")
                .setAttribute("gen_ai.tool.name", methodName)
                .setAttribute("gen_ai.tool.call.id", methodName + "-" + System.nanoTime())
                .startSpan();

        // Record first arg as input summary (truncated)
        Object[] args = joinPoint.getArgs();
        if (args.length > 0 && args[0] instanceof String s) {
            span.setAttribute("gen_ai.tool.input", s.substring(0, Math.min(200, s.length())));
        }

        try (var scope = span.makeCurrent()) {
            Object result = joinPoint.proceed();
            if (result instanceof String s) {
                span.setAttribute("gen_ai.tool.output.size", s.length());
            }
            return result;
        } catch (Throwable t) {
            span.setStatus(StatusCode.ERROR, t.getMessage());
            span.recordException(t);
            throw t;
        } finally {
            span.end();
        }
    }
}
