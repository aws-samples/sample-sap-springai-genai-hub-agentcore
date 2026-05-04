# SAP Supply Chain Agent — AgentCore Gateway

Extends [`sapsupplychainagent-with-gui-agentcore-memory`](../sapsupplychainagent-with-gui-agentcore-memory) with an **AWS AgentCore Gateway** that exposes the Product Catalog service as an MCP endpoint. The agent calls the product catalog via the Gateway using OAuth2 `client_credentials` — no direct HTTP to the backend.

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
                  ┌─────────────────────────────────────────────┐
                  │  ChainWorkflowService                        │
                  │  Step 1 — selectApi (SAP OData)              │──► SAP S/4HANA
                  │  Step 2 — executeApi                         │    OData API
                  │  Step 3 — format (Memory + MCP tools)        │
                  └──────────────────────┬──────────────────────┘
                                         │ MCP client (OAuth2 client_credentials)
                                         ▼
                  ┌──────────────────────────────────────────────┐
                  │  AgentCore Gateway                            │
                  │  MCP over HTTPS · Cognito M2M auth           │
                  └──────────────────────┬───────────────────────┘
                                         │
                                         ▼
                  ┌────────────────────────────────────┐
                  │  Product Catalog Service            │
                  │  AWS Lambda (Java 21 + SnapStart)   │
                  │  API Gateway (x-api-key auth)       │
                  └────────────────────────────────────┘
                  AgentCore Memory · SAP GenAI Hub · X-Ray
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
| Gateway protocol | MCP (AgentCore Gateway) |
| Gateway auth | CUSTOM_JWT (Cognito) |

---

## Project Structure

```
src/main/java/com/example/sapaiagent/
├── SapaiagentApplication.java
├── config/
│   ├── GatewayMcpOAuth2Config.java        # WebClient with OAuth2 client_credentials filter
│   ├── OtelTracingConfig.java             # Tracer bean backed by GlobalOpenTelemetry
│   └── ToolSpanAspect.java                # AOP aspect — auto-instruments @Tool methods
├── controller/
│   └── InvocationController.java          # @AgentCoreInvocation — extracts userId + sessionId
├── model/
│   ├── InvocationRequest.java
│   └── SAPOdataAPISpec.java
└── service/
    ├── SAPAIOrchestrationService.java
    ├── ChainWorkflowService.java           # 3-step chain with Memory + MCP Gateway tools
    ├── SAPOdataApiSpecLoader.java
    ├── SAPOdataApiSelectorTool.java        # @Tool: selectApi
    ├── SAPApiExecutorTool.java             # @Tool: executeApi
    ├── DateTimeTools.java                  # @Tool: getCurrentDateTime
    └── WeatherTools.java                   # @Tool: getWeatherForecast
```

---

## How It Works

### What was added vs the memory project

| File | Change |
|---|---|
| `config/GatewayMcpOAuth2Config.java` | `WebClient.Builder` bean with a filter that fetches a Cognito Bearer token via `client_credentials` flow and injects it on requests to the Gateway — token is cached and refreshed before expiry |
| `application.properties` | MCP client connection pointing to `${PRODUCT_CATALOG_GATEWAY_URL}/mcp` |
| `deploy/cloudformation/infra.yaml` | Adds `GatewayRole`, Cognito resource server for the `gateway-api/invoke` M2M scope |

OAuth2 config (client ID, secret, token URI, scope) is injected as environment variables by `deploy.sh` — nothing is hardcoded.

---

## Prerequisites

- **`AICORE_SERVICE_KEY`** — SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)
- **`SAP_S4HANA_PUBLIC_CLOUD_KEY`** — SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key**
- **Deploy `product-catalog-service` first** — its `PRODUCT_CATALOG_URL` and `PRODUCT_CATALOG_API_KEY` are required
- AWS CLI configured with permissions for ECR, IAM, Cognito, AgentCore, S3, CloudFront, Secrets Manager, X-Ray, CloudWatch
- `docker`, `jq`, and `curl` installed

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

## Environment Variables (injected by deploy.sh)

| Variable | Description |
|---|---|
| `AICORE_SERVICE_KEY` | SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key) |
| `SAP_S4HANA_PUBLIC_CLOUD_KEY` | SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key** |
| `AGENTCORE_MEMORY_MEMORY_ID` | AgentCore Memory resource ID |
| `GATEWAY_CLIENT_ID` | Cognito M2M client ID for Gateway OAuth2 |
| `GATEWAY_CLIENT_SECRET` | Cognito M2M client secret |
| `GATEWAY_TOKEN_ENDPOINT` | Cognito token endpoint |
| `GATEWAY_SCOPE` | OAuth2 scope (`gateway-api/invoke`) |
| `PRODUCT_CATALOG_GATEWAY_URL` | AgentCore Gateway base URL (without `/mcp`) |

---

## Build & Run

```bash
cd examples/sapsupplychainagent-with-agentcore-gateway
./mvnw spring-boot:run   # default port: 9090
```

Without `PRODUCT_CATALOG_GATEWAY_URL`, the product catalog MCP tool is unavailable — all other tools still work.

---

## Deploy to AWS (CloudFormation)

### 1 — Configure

```bash
cd examples/sapsupplychainagent-with-agentcore-gateway
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit .env — set:
#   AICORE_SERVICE_KEY, SAP_S4HANA_PUBLIC_CLOUD_KEY
#   PRODUCT_CATALOG_URL, PRODUCT_CATALOG_API_KEY
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script deploys infrastructure, sets up the AgentCore Memory resource, creates the Cognito M2M client and credential provider, registers the Product Catalog OpenAPI spec as a Gateway MCP target, and deploys the runtime with all Gateway OAuth2 variables injected.

### 3 — Create a test user and test

```bash
source deploy/cloudformation/.runtime-state

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-gateway-infra \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-gateway-infra \
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

# Product catalog query (uses MCP via Gateway)
curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: test-session-gateway-$(date +%s)-001" \
  -d '{"prompt":"Show me all products in the catalog"}'

# SAP supply chain query
curl -s -X POST "$RUNTIME_ENDPOINT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: test-session-gateway-$(date +%s)-001" \
  -d '{"prompt":"What are open purchase orders?"}'
```

> The `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header must be **at least 33 characters**.

### 4 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```

Cleanup removes (in order): Gateway targets, Gateway, credential provider, Cognito M2M client, AgentCore runtime, Memory resource, S3 contents, ECR repository, CloudFormation stack.
