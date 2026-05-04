package com.example.a2a.context;

/**
 * Thread-local carrier for the current user's session ID.
 *
 * The orchestrator sets this before calling ChatClient.prompt(). Because
 * setInternalToolExecutionEnabled(true) causes the SAP SDK to execute
 * RemoteAgentToolCallback.call() synchronously on the same thread,
 * every A2A worker call inherits the same session ID — tying all downstream
 * calls back to the authenticated user without changing the ToolCallback interface.
 *
 * Usage:
 *   A2ASessionContext.set(sessionId);
 *   try {
 *       chatClient.prompt(...).call();
 *   } finally {
 *       A2ASessionContext.clear();
 *   }
 */
public final class A2ASessionContext {

    private static final ThreadLocal<String> SESSION_ID = new ThreadLocal<>();

    private A2ASessionContext() {}

    public static void set(String sessionId) {
        SESSION_ID.set(sessionId);
    }

    public static String get() {
        return SESSION_ID.get();
    }

    public static void clear() {
        SESSION_ID.remove();
    }
}
