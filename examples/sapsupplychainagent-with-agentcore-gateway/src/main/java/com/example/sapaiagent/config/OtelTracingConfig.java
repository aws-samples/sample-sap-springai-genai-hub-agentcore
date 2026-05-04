package com.example.sapaiagent.config;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Tracer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OtelTracingConfig {

    @Bean
    Tracer otelTracer() {
        // Return a lazy-delegating tracer. The ADOT agent sets GlobalOpenTelemetry
        // before Spring starts, but the Tracer must be fetched fresh to ensure
        // it's backed by the agent's SDK (not a noop).
        return new LazyTracer();
    }

    /**
     * Delegates every call to GlobalOpenTelemetry.getTracer() at invocation time,
     * guaranteeing the ADOT agent's TracerProvider is used.
     */
    static class LazyTracer implements Tracer {
        private Tracer delegate() {
            return GlobalOpenTelemetry.getTracer("sapaiagent", "0.1.0");
        }

        @Override
        public io.opentelemetry.api.trace.SpanBuilder spanBuilder(String spanName) {
            return delegate().spanBuilder(spanName);
        }
    }
}
