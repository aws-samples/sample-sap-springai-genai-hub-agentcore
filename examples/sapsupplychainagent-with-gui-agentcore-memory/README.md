# SAP Supply Chain Agent — AgentCore Memory

Builds on [`sapsupplychainagent-with-gui-agentcore-observability`](../sapsupplychainagent-with-gui-agentcore-observability) and adds persistent **AWS AgentCore Memory** — Short-Term Memory (STM) and Long-Term Memory (LTM).

> This project is **fully self-contained** — the observability project does not need to be deployed first.

---

## Architecture

```
   Browser
     │
     ▼
┌──────────────┐  ┌─────────────────┐
│  CloudFront  │  │  Amazon Cognito │
│  (GUI)       │─►│  JWT authorizer │
└──────────────┘  └────────┬────────┘
                           │
                           ▼
                  ┌─────────────────────────┐
                  │  AgentCore Runtime       │
                  │  @AgentCoreInvocation    │
                  └────────────┬─────────────┘
                               │
                               ▼
                  ┌──────────────────────────────────────┐
                  │  ChainWorkflowService                 │
                  │  Step 3 — MessageChatMemoryAdvisor    │
                  │  ┌─────────────────────────────────┐ │
                  │  │  AgentCoreShortTermMemoryRepo.  │ │
                  │  │  (deployed) / InMemory (local)  │ │
                  │  └─────────────────────────────────┘ │
                  └────────────────┬─────────────────────┘
                                   │
                                   ▼
                  ┌────────────────────────────────────────┐
                  │       AgentCore Memory                  │
                  │  ┌─────────────────────────────────┐   │
                  │  │  Short-Term Memory (STM)        │   │
                  │  │  last 20 msgs per user          │   │
                  │  ├─────────────────────────────────┤   │
                  │  │  Long-Term Memory (LTM)         │   │
                  │  │  facts: user context/knowledge  │   │
                  │  │  prefs: user preferences        │   │
                  │  └─────────────────────────────────┘   │
                  └────────────────────────────────────────┘
                  SAP GenAI Hub (claude-4-5-sonnet via Bedrock)
                  AWS CloudWatch / X-Ray (ADOT + OTEL tracing)
```

---

## Stack

| Component | Version |
|---|---|
| Java | 25 |
| Spring Boot | 3.5.11 |
| Spring AI | 1.1.2 |
| SAP AI SDK | 1.16.0 |
| [Spring AI AgentCore SDK](https://github.com/spring-ai-community/spring-ai-agentcore) | `1.0.0` |
| Model | `claude-4-5-sonnet` |

---

## Project Structure

```
src/main/java/com/example/sapaiagent/
├── SapaiagentApplication.java
├── config/
│   ├── OtelTracingConfig.java             # Tracer bean backed by GlobalOpenTelemetry
│   └── ToolSpanAspect.java                # AOP aspect — auto-instruments @Tool methods
├── controller/
│   └── InvocationController.java          # @AgentCoreInvocation — extracts userId + sessionId
├── model/
│   ├── InvocationRequest.java
│   └── SAPOdataAPISpec.java
└── service/
    ├── SAPAIOrchestrationService.java
    ├── ChainWorkflowService.java           # 3-step chain with AgentCore Memory integration
    ├── SAPOdataApiSpecLoader.java
    ├── SAPOdataApiSelectorTool.java        # @Tool: selectApi
    ├── SAPApiExecutorTool.java             # @Tool: executeApi
    ├── DateTimeTools.java                  # @Tool: getCurrentDateTime
    └── WeatherTools.java                   # @Tool: getWeatherForecast
```

---

## How It Works

### What was added vs the observability project

| File | Change |
|---|---|
| `pom.xml` | Added `spring-ai-agentcore-memory` dependency |
| `application.properties` | Added `agentcore.memory.*` configuration (memory ID, LTM auto-discovery, namespace auto-register) |
| `service/ChainWorkflowService.java` | Constructor now accepts `@Nullable ChatMemoryRepository` — uses `AgentCoreShortTermMemoryRepository` when deployed, falls back to `InMemoryChatMemoryRepository` locally |

`MessageChatMemoryAdvisor` handles loading and saving conversation history automatically. No other code changes.

### Short-Term Memory (STM)

`MessageChatMemoryAdvisor` is attached on Step 3 (the text-only formatting step). It loads the last 20 messages for the user and saves the exchange after each invocation. With AgentCore Memory, this persists across container restarts and scaling events. Locally (no `AGENTCORE_MEMORY_MEMORY_ID`), it falls back to in-memory storage.

### Long-Term Memory (LTM)

AgentCore asynchronously processes stored events through two strategies:

| Strategy | What it extracts | Example |
|---|---|---|
| **Semantic** (`facts`) | Factual knowledge about the user | "User manages warehouse WH-1200 in Hamburg" |
| **User Preference** (`prefs`) | User preferences and settings | "Prefers freight data in metric tons" |

LTM persists across sessions. The `spring-ai-agentcore-memory` library auto-creates LTM advisors that enrich prompts with recalled knowledge when `auto-discovery: true` is configured.

---

## Prerequisites

- **`AICORE_SERVICE_KEY`** — SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)
- **`SAP_S4HANA_PUBLIC_CLOUD_KEY`** — SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key**
- AWS CLI configured with permissions for ECR, IAM, Cognito, AgentCore, S3, CloudFront, X-Ray, CloudWatch
- `docker` and `jq` installed

> **Docker daemon must be running**
>
> The deployment scripts build and push a Docker image to Amazon ECR. If the Docker daemon is not running when you execute `deploy.sh`, the script will fail. Start Docker Desktop (or your Docker daemon) before running any deployment script.

> **Security note — `.env` file**
>
> The `.env` file is gitignored and must never be committed. It contains `AICORE_SERVICE_KEY`, a full SAP BTP service key JSON that grants access to SAP AI Core. This is provided for local convenience in this sample only.
>
> For more secure alternatives:
> - **Export variables directly** — set `AICORE_SERVICE_KEY` and `SAP_S4HANA_PUBLIC_CLOUD_KEY` as shell environment variables before running the script; the `.env` file is optional if the variables are already set.
> - **SAP AI SDK service binding** — the SAP Cloud SDK for AI supports providing the service binding via `VCAP_SERVICES` or a local `default-env.json` file: [Providing a Service Binding Locally](https://sap.github.io/ai-sdk/docs/java/connecting-to-ai-core#providing-a-service-binding-locally)
> - **AWS Secrets Manager** — store the service key in a secret and retrieve it in the script via `aws secretsmanager get-secret-value` before passing it as an env var to the AgentCore runtime.

---

## Environment Variables

| Variable | Description |
|---|---|
| `AICORE_SERVICE_KEY` | SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key) |
| `SAP_S4HANA_PUBLIC_CLOUD_KEY` | SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key** |

---

## Build & Run

```bash
cd examples/sapsupplychainagent-with-gui-agentcore-memory
./mvnw spring-boot:run
```

Without `AGENTCORE_MEMORY_MEMORY_ID`, the app falls back to `InMemoryChatMemoryRepository`.

---

## Deploy to AWS (CloudFormation)

### 1 — Configure

```bash
cd examples/sapsupplychainagent-with-gui-agentcore-memory
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit .env — set AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script deploys infrastructure, creates the AgentCore Memory resource (90-day retention, semantic + user preference strategies), builds and pushes the Docker image, and creates the runtime with the memory ID injected as an environment variable.

### 3 — Create a test user and test

```bash
source deploy/cloudformation/.runtime-state

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-memory-infra \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-memory-infra \
  --query "Stacks[0].Outputs[?OutputKey=='AppClientId'].OutputValue" --output text)

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --user-attributes Name=email,Value=testuser@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --password "TestPass123#" --permanent

ACCESS_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=TestPass123# \
  --client-id "$CLIENT_ID" | jq -r '.AuthenticationResult.AccessToken')

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${RUNTIME_ID}"
RUNTIME_ARN_ENCODED=$(echo -n "${RUNTIME_ARN}" | jq -sRr @uri)
RUNTIME_ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ARN_ENCODED}/invocations?qualifier=DEFAULT"

curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: test-session-memory-$(date +%s)-001" \
  -d '{"prompt":"Show me the latest freight bookings"}'
```

> The `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header must be **at least 33 characters**.

### 4 — Test memory persistence

**STM — conversation continuity (same session ID):**

```bash
SESSION_ID="stm-test-session-$(date +%s)-00000001"

curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"prompt": "Show me the latest freight bookings"}'

curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"prompt": "Filter those to only Hamburg warehouse"}'
```

**LTM — cross-session recall (different session IDs):**

```bash
# Set a preference in one session
curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: ltm-test-session-$(date +%s)-001" \
  -d '{"prompt": "I always want freight data in metric tons, and I manage warehouse WH-1200 in Hamburg"}'

# Wait ~10 seconds for LTM extraction, then start a new session
curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: ltm-test-session-$(date +%s)-002" \
  -d '{"prompt": "Show me freight orders for next week"}'
```

The agent should recall the Hamburg warehouse and metric tons preference from the previous session.

### 5 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```
