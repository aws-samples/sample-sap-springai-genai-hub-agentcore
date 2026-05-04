# SAP Supply Chain Agent — AWS AgentCore Deployment

The chain workflow agent from [`sapsupplychainagent-using-chain-workflow-pattern`](../sapsupplychainagent-using-chain-workflow-pattern) packaged for **deployment to AWS AgentCore runtime**. The controller uses `@AgentCoreInvocation` instead of a standard REST mapping, and user identity is extracted from the JWT `Authorization` header via `AgentCoreContext`.

---

## Architecture

```
   Browser
     │
     ▼
┌────────────────────────┐     ┌─────────────────┐
│  CloudFront (GUI)      │     │  Amazon Cognito  │
│  S3 static assets      │────►│  User Pool       │
└────────────────────────┘     │  JWT authorizer  │
                               └────────┬─────────┘
                                        │ Bearer token
                                        ▼
                               ┌─────────────────────────┐
                               │  AgentCore Runtime       │
                               │  InvocationController    │
                               │  @AgentCoreInvocation    │
                               └────────────┬─────────────┘
                                            │
                                            ▼
                               ┌─────────────────────────────────┐
                               │   ChainWorkflowService          │
                               │   Step 1 — selectApi            │
                               │   Step 2 — executeApi           │──► SAP S/4HANA
                               │   Step 3 — format               │    OData API
                               │   Memory: InMemory (local)      │
                               └────────────┬────────────────────┘
                                            │
                                            ▼
                               SAP GenAI Hub (claude-4-5-sonnet via Bedrock)
                               MCP: AWS Knowledge Base
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
| MCP Server | AWS Knowledge Base (`knowledge-mcp.global.api.aws`) |

---

## Project Structure

```
src/main/java/com/example/sapaiagent/
├── SapaiagentApplication.java
├── controller/
│   └── InvocationController.java          # @AgentCoreInvocation handler
├── model/
│   ├── InvocationRequest.java
│   └── SAPOdataAPISpec.java
└── service/
    ├── SAPAIOrchestrationService.java      # Entry point — delegates to ChainWorkflowService
    ├── ChainWorkflowService.java           # 3-step chain
    ├── SAPOdataApiSpecLoader.java
    ├── SAPOdataApiSelectorTool.java        # @Tool: selectApi
    ├── SAPApiExecutorTool.java             # @Tool: executeApi
    ├── DateTimeTools.java                  # @Tool: getCurrentDateTime
    └── WeatherTools.java                   # @Tool: getWeatherForecast
```

---

## How It Works

Identical to [`sapsupplychainagent-using-chain-workflow-pattern`](../sapsupplychainagent-using-chain-workflow-pattern) — 3-step sequential chain:

1. **Step 1 — Analyze & Select**: LLM calls `selectApi`. Short-circuits with `[FINAL]` for non-SAP queries.
2. **Step 2 — Execute SAP API**: LLM calls `executeApi` with details from Step 1.
3. **Step 3 — Format Response**: LLM formats the final answer with no tool overhead.

The controller method is annotated with `@AgentCoreInvocation` — AgentCore invokes it directly without an explicit path mapping. User identity is resolved by checking the `AgentCoreHeaders.USER_ID` header first (injected by the JWT authorizer), then falling back to parsing the `sub` claim from the JWT, and finally to `ANONYMOUS_USER`.

---

## Prerequisites

- **`AICORE_SERVICE_KEY`** — SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)
- **`SAP_S4HANA_PUBLIC_CLOUD_KEY`** — SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key**
- AWS CLI configured with permissions for ECR, IAM, Cognito, Bedrock AgentCore, S3, CloudFront
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
cd examples/sapsupplychainagent-with-gui-agentcore-deployment
./mvnw spring-boot:run   # default port: 9090
```

---

## Deploy to AWS (CloudFormation)

### 1 — Configure

```bash
cd examples/sapsupplychainagent-with-gui-agentcore-deployment
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit .env — set AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script deploys the CloudFormation stack (ECR, IAM, Cognito, S3, CloudFront), builds and pushes the Docker image, creates the AgentCore runtime with a Cognito JWT authorizer, and uploads the GUI.

### 3 — Create a test user

```bash
source deploy/cloudformation/.runtime-state

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-deployment-infra \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name sapaiagent-deployment-infra \
  --query "Stacks[0].Outputs[?OutputKey=='AppClientId'].OutputValue" --output text)

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --user-attributes Name=email,Value=testuser@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --password "TestPass123#" --permanent
```

> Self-registration is disabled on the Cognito User Pool — users must be created via the CLI or AWS Console.

### 4 — Test

```bash
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
  -d '{"prompt":"What are open purchase orders?"}'
```

### 5 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```
