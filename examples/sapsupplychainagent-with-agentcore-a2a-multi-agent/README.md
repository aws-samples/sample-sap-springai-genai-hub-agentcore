# SAP Supply Chain Multi-Agent A2A System

A distributed multi-agent system using the **A2A protocol (JSON-RPC 2.0)**, deployed to **AWS AgentCore**. Five independently deployable agents collaborate to answer SAP supply chain, date/weather, and AWS knowledge base queries.

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
                  ┌──────────────────────────────┐
                  │  Orchestrator Agent           │
                  │  AgentCore Runtime (port 8080)│
                  │  @AgentCoreInvocation         │
                  │  Discovers workers at startup │
                  │  (agent-card.json)            │
                  └──────┬───────────────────────┘
                         │ InvokeAgentRuntime API (SigV4)
                         │ A2A JSON-RPC 2.0
             ┌───────────┼─────────────────────────┐
             ▼           ▼           ▼              ▼
    ┌─────────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ sap-query   │ │sap-exec- │ │date-wea- │ │mcp-tools │
    │ -agent      │ │format-   │ │ther-     │ │-agent    │
    │ selectApi   │ │agent     │ │agent     │ │AWS KB MCP│
    │             │ │executeApi│ │DateTime  │ │+ Product │
    │ port 9000   │ │+format   │ │+ Weather │ │Catalog   │
    └─────────────┘ └──────────┘ └──────────┘ └──────────┘
    Each worker: AgentCore A2A Runtime · port 9000
    Exposes: /.well-known/agent-card.json · POST / · GET /ping

    AgentCore Memory · SAP GenAI Hub (claude-4-5-sonnet via Bedrock)
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
| A2A Protocol | JSON-RPC 2.0 (manually implemented — `spring-ai-a2a` requires Boot 4.x, incompatible with SAP AI SDK 1.x) |

---

## Project Structure

```
sapsupplychainagent-with-agentcore-a2a-multi-agent/
├── pom.xml                          # Parent POM — shared versions
├── a2a-common/                      # Shared library (A2A models, client, server controller)
├── orchestrator-agent/              # HTTP protocol — @AgentCoreInvocation entry point
├── sap-query-agent/                 # A2A — selects SAP OData API endpoint
├── sap-execute-format-agent/        # A2A — executes SAP API and formats response
├── date-weather-agent/              # A2A — date/time and weather queries
├── mcp-tools-agent/                 # A2A — AWS KB MCP + product catalog Gateway
└── deploy/
    └── cloudformation/
        ├── .env.example
        ├── infra.yaml
        ├── deploy.sh
        └── cleanup.sh
```

---

## How It Works

The orchestrator runs as an **HTTP protocol** AgentCore runtime (port 8080, `/invocations`). Worker agents run as **A2A protocol** runtimes (port 9000, `POST /`). The orchestrator calls workers via the `InvokeAgentRuntime` API, with all requests signed using SigV4 from the execution role.

| Protocol | Port | Path | Used by |
|---|---|---|---|
| HTTP | 8080 | `/invocations` | Orchestrator |
| A2A | 9000 | `/` | All 4 worker agents |

Each worker exposes `GET /.well-known/agent-card.json` for discovery, `POST /` for JSON-RPC 2.0 invocation, and `GET /ping` for health checks. The orchestrator discovers worker endpoints at startup and wraps each as a `RemoteAgentToolCallback` — a Spring AI `ToolCallback` the LLM can invoke as a tool.

---

## Prerequisites

- **`AICORE_SERVICE_KEY`** — SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)
- **`SAP_S4HANA_PUBLIC_CLOUD_KEY`** — SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key**
- AWS CLI configured with permissions for ECR, CloudFormation, IAM, Cognito, Bedrock AgentCore, S3, CloudFront
- `docker` running

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

| Variable | Required | Description |
|---|---|---|
| `AICORE_SERVICE_KEY` | Yes | SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key) |
| `SAP_S4HANA_PUBLIC_CLOUD_KEY` | Yes | SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key** |
| `PRODUCT_CATALOG_GATEWAY_URL` | No | AgentCore Gateway URL — activates product catalog MCP when set |
| `GATEWAY_CLIENT_ID` | No | OAuth2 client ID for Gateway |
| `GATEWAY_CLIENT_SECRET` | No | OAuth2 client secret for Gateway |
| `GATEWAY_TOKEN_ENDPOINT` | No | OAuth2 token endpoint for Gateway |
| `A2A_AGENTS_*_URL` | Auto | Worker invoke URLs — set by `deploy.sh` |
| `AGENTCORE_MEMORY_MEMORY_ID` | Auto | AgentCore Memory resource ID — set by `deploy.sh` |

---

## Local Development

### Build All Modules

```bash
cd examples/sapsupplychainagent-with-agentcore-a2a-multi-agent
./mvnw clean install -DskipTests
```

### Run Agents Locally

Start workers first, then the orchestrator:

```bash
./mvnw -pl sap-query-agent spring-boot:run           # port 9091
./mvnw -pl sap-execute-format-agent spring-boot:run  # port 9092
./mvnw -pl date-weather-agent spring-boot:run        # port 9093
./mvnw -pl mcp-tools-agent spring-boot:run           # port 9094 (optional)
./mvnw -pl orchestrator-agent spring-boot:run        # port 9090 — start last
```

### Test Locally

```bash
curl -s -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" -H "Authorization: alice" \
  -d '{"prompt": "What is todays date and time?"}'

curl -s -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" -H "Authorization: alice" \
  -d '{"prompt": "Show me recent freight bookings"}'

# Verify agent discovery
curl http://localhost:9091/.well-known/agent-card.json | jq .name
```

---

## Deploy to AWS AgentCore

### 1 — Configure

```bash
cd examples/sapsupplychainagent-with-agentcore-a2a-multi-agent
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit .env — set AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY
# Optional: set PRODUCT_CATALOG_GATEWAY_URL and gateway credentials
#           (from sapsupplychainagent-with-agentcore-gateway .runtime-state)
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script deploys CloudFormation infrastructure, builds all modules, pushes Docker images (single ECR repo, per-agent tags, `linux/arm64`), deploys 4 worker A2A runtimes in parallel, creates an AgentCore Memory resource, deploys the orchestrator HTTP runtime, and uploads the GUI.

### 3 — Create a test user and test

```bash
source deploy/cloudformation/.runtime-config
source deploy/cloudformation/.cloudfront-config

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CF_STACK_NAME="${PROJECT_NAME:-sap-a2a-multi-agent}-infra"

USER_POOL_ID=$(aws cloudformation describe-stacks \
  --stack-name "$CF_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoUserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name "$CF_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CognitoAppClientId'].OutputValue" --output text)

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --user-attributes Name=email,Value=testuser@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" --username testuser@example.com \
  --password "TestPass123#" --permanent

ACCESS_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=testuser@example.com,PASSWORD=TestPass123#" \
  --client-id "$CLIENT_ID" | jq -r '.AuthenticationResult.AccessToken')

ORCH_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${ORCH_RUNTIME_ID}"
ORCH_ARN_ENCODED=$(echo -n "${ORCH_ARN}" | jq -sRr @uri)
ORCH_ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${ORCH_ARN_ENCODED}/invocations?qualifier=DEFAULT"

SESSION_ID="a2a-test-session-$(date +%s)-00000001"

curl -s -X POST "$ORCH_ENDPOINT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"prompt":"What is the current date and time in Tokyo?"}'

curl -s -X POST "$ORCH_ENDPOINT" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: $SESSION_ID" \
  -d '{"prompt":"Show me recent freight bookings"}'
```

> The `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` header must be **at least 33 characters**. The orchestrator propagates it to all A2A worker agents for trace correlation.

### 4 — Open the GUI

```bash
echo "https://${CF_DOMAIN}"
```

Log in with `testuser@example.com` / `TestPass123#`.

### 5 — Enable tracing (manual, one-time)

Enable **CloudWatch Transaction Search** and toggle **Enable tracing** for all 5 runtimes (orchestrator + 4 workers) in **Amazon Bedrock → AgentCore → Runtimes**. See the observability project for detailed steps.

### 6 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```

Removes all 5 runtimes, AgentCore Memory, S3 contents, ECR repository, and CloudFormation stack.
