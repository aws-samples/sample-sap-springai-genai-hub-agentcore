# SAP Supply Chain Agent — AgentCore Observability

Builds on [`sapsupplychainagent-with-gui-agentcore-deployment`](../sapsupplychainagent-with-gui-agentcore-deployment) and adds full **AWS AgentCore Observability** using the OpenTelemetry API and the AWS Distro for OpenTelemetry (ADOT) Java agent.

> This project is **fully self-contained** — the base deployment project does not need to be deployed first.

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
                           │ Bearer token + session ID header
                           ▼
                  ┌─────────────────────────┐
                  │  AgentCore Runtime       │
                  │  @AgentCoreInvocation    │
                  │  ┌─────────────────────┐ │
                  │  │   ADOT Java Agent   │ │
                  │  │   (javaagent JAR)   │ │
                  │  └─────────────────────┘ │
                  └────────────┬─────────────┘
                               │
                               ▼
                  ┌──────────────────────────────────────┐
                  │  ChainWorkflowService                 │
                  │  invoke_agent span                    │
                  │  ┌────────────────────────────────┐  │
                  │  │ execute_agent_step 1           │  │
                  │  │   execute_tool selectApi       │  │
                  │  ├────────────────────────────────┤  │
                  │  │ execute_agent_step 2           │  │
                  │  │   execute_tool executeApi      │  │──► SAP S/4HANA
                  │  ├────────────────────────────────┤  │
                  │  │ execute_agent_step 3           │  │
                  │  └────────────────────────────────┘  │
                  │  ToolSpanAspect (AOP auto-instrument) │
                  └────────────────┬─────────────────────┘
                                   │ OTEL spans
                                   ▼
                  ┌─────────────────────────────────────┐
                  │  AWS CloudWatch / X-Ray              │
                  │  (Transaction Search + GenAI traces) │
                  └─────────────────────────────────────┘
                  SAP GenAI Hub (claude-4-5-sonnet via Bedrock)
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
    ├── ChainWorkflowService.java           # invoke_agent + execute_agent_step OTEL spans
    ├── SAPOdataApiSpecLoader.java
    ├── SAPOdataApiSelectorTool.java        # @Tool: selectApi
    ├── SAPApiExecutorTool.java             # @Tool: executeApi
    ├── DateTimeTools.java                  # @Tool: getCurrentDateTime
    └── WeatherTools.java                   # @Tool: getWeatherForecast
```

---

## How It Works

### What was added vs the base deployment project

| File | Change |
|---|---|
| `pom.xml` | Added `opentelemetry-api` (compile-time) and `spring-boot-starter-aop` |
| `Dockerfile` | Downloads ADOT Java agent at build time; attaches via `-javaagent` in `CMD` |
| `application.properties` | Enables Spring AI prompt/completion observations and actuator endpoints |
| `config/OtelTracingConfig.java` | Exposes a `Tracer` Spring bean backed by `GlobalOpenTelemetry` via a lazy wrapper |
| `config/ToolSpanAspect.java` | AOP aspect that automatically wraps every `@Tool`-annotated method in an OTEL span following GenAI semantic conventions — no per-tool instrumentation needed |
| `service/ChainWorkflowService.java` | Adds `invoke_agent` and `execute_agent_step` spans with GenAI attributes; propagates `session.id` via OTEL Baggage |
| `controller/InvocationController.java` | Extracts `sessionId` from the `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header for span correlation |
| GUI (`auth.js` / `chat.js`) | Generates a stable `username-UUID` session ID on login (≥33 chars); sends it as the AgentCore session header on every request |

OTEL environment variables (service name, exporter endpoint, propagators) are injected by `deploy.sh` — nothing is hardcoded in the application.

### Trace hierarchy

For a SAP query:

```
invoke_agent sap-supply-chain-agent
  ├─ execute_agent_step 1-analyze-select
  │    ├─ execute_tool selectApi
  │    └─ execute_tool getCurrentDateTime   (if called)
  ├─ execute_agent_step 2-execute-api
  │    └─ execute_tool executeApi
  │         └─ HTTP GET sandbox.api.sap.com/...   (auto-instrumented by ADOT)
  └─ execute_agent_step 3-format-response
```

For a non-SAP query (short-circuit after Step 1):

```
invoke_agent sap-supply-chain-agent   [short_circuit=true]
  └─ execute_agent_step 1-analyze-select
       └─ execute_tool getWeatherForecast
            └─ HTTP GET api.open-meteo.com/...   (auto-instrumented by ADOT)
```

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
cd examples/sapsupplychainagent-with-gui-agentcore-observability
./mvnw spring-boot:run   # tracing inactive without ADOT agent
```

To test tracing locally with Jaeger:

```bash
# Start Jaeger (OTLP receiver + UI)
docker run --rm -d --name jaeger -p 4318:4318 -p 16686:16686 jaegertracing/all-in-one:latest

# Download ADOT agent once
curl -L -o /tmp/aws-opentelemetry-agent.jar \
  https://github.com/aws-observability/aws-otel-java-instrumentation/releases/latest/download/aws-opentelemetry-agent.jar

# Run with tracing enabled
./mvnw spring-boot:run \
  -Dspring-boot.run.jvmArguments="-javaagent:/tmp/aws-opentelemetry-agent.jar \
  -Dotel.exporter.otlp.protocol=http/protobuf \
  -Dotel.logs.exporter=none \
  -Dotel.metrics.exporter=none \
  -Dotel.service.name=sapaiagent"
```

Open `http://localhost:16686`, select service **sapaiagent**, click **Find Traces**.

---

## Deploy to AWS (CloudFormation)

### 1 — Configure

```bash
cd examples/sapsupplychainagent-with-gui-agentcore-observability
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit .env — set AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script deploys CloudFormation infrastructure, builds and pushes the Docker image, creates the AgentCore runtime with OTEL env vars configured, and uploads the GUI.

### 3 — Enable observability (manual, one-time)

Two settings must be enabled from the AWS Console after the first deployment:

**A. Enable CloudWatch Transaction Search**
1. Go to **CloudWatch → X-Ray → Settings**
2. Under **Transaction Search**, click **Enable**

**B. Enable tracing on the AgentCore runtime**
1. Go to **Amazon Bedrock → AgentCore → Runtimes**
2. Select the runtime → **Edit** → toggle **Enable tracing** on → Save

### 4 — Create a test user and test

```bash
source deploy/cloudformation/.runtime-state

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-observability-infra \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-observability-infra \
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
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: test-session-eval-$(date +%s)-001" \
  -d '{"prompt":"Show me the latest freight bookings"}'
```

> The `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header must be **at least 33 characters**. Use the same value across multiple requests to group them into one session in CloudWatch.

### 5 — View traces

Allow ~2 minutes after sending requests, then check:

- **CloudWatch → X-Ray → Traces** (filter by service `sapaiagent`)
- **CloudWatch → Application Signals → GenAI → Agents**

### 6 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```
