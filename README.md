# SAP Spring AI — GenAI Hub & AWS AgentCore Examples

A collection of Java code samples showing how to build and deploy production-ready AI agents on [Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/) using [Spring AI](https://spring.io/projects/spring-ai) with the [Spring AI AgentCore SDK](https://github.com/spring-ai-community/spring-ai-agentcore) and the [SAP Cloud SDK for AI](https://sap.github.io/ai-sdk/docs/java/overview-cloud-sdk-for-ai-java). Covers agentic patterns (Chain Workflow, Orchestrator-Workers), AgentCore deployment with observability, persistent memory, MCP gateway, and a multi-agent A2A system — all invoking Claude via SAP GenAI Hub.

Key frameworks: Spring AI 1.1.2 · SAP AI SDK 1.16.0 · Spring Boot 3.5.11 · Spring AI AgentCore SDK 1.0.0

---

> **⚠️ Sample Code Notice**
>
> This is sample code for demonstration and educational purposes only. It is not intended for production use without significant modifications and additional security hardening. This code is provided "as-is" with no warranty or support guarantees.

> **⚠️ Cost Warning**
>
> Deploying the AWS examples (5–9) will incur charges for Amazon Bedrock AgentCore runtime invocations, ECR image storage, Cognito user pool, CloudFront distributions, S3 storage, Lambda invocations (product-catalog-service), API Gateway requests, CloudWatch logs and X-Ray traces, and AgentCore Memory. Always run `cleanup.sh` after testing to avoid ongoing charges.

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

## What this repository demonstrates

- **SAP AI SDK + Spring AI integration** — invoke LLMs (Claude via Amazon Bedrock) through SAP GenAI Hub using standard Spring AI abstractions
- **Agentic patterns** — sequential chain workflow and orchestrator-workers with parallel execution
- **AWS AgentCore features** — containerized deployment, distributed tracing (OTEL/X-Ray with GenAI semantic conventions), persistent memory (short-term + long-term with fact/preference extraction), gateway (MCP over OAuth2), and multi-agent A2A protocol

---

## Spring AI SDK for Amazon Bedrock AgentCore

Examples 5–9 use the [**Spring AI SDK for Amazon Bedrock AgentCore**](https://github.com/spring-ai-community/spring-ai-agentcore)
— a Spring community library ([now Generally Available](https://aws.amazon.com/blogs/machine-learning/spring-ai-sdk-for-amazon-bedrock-agentcore-is-now-generally-available/))
that integrates AgentCore capabilities into Spring AI applications using Spring Boot auto-configuration.

The SDK modules used in these examples:
- **`spring-ai-agentcore-runtime-starter`** — auto-configures `/invocations` and `/ping` endpoints, SSE streaming, health checks, and the `@AgentCoreInvocation` annotation
- **`spring-ai-agentcore-memory`** — short-term (conversation history) and long-term memory (semantic, preferences, summaries, episodic) via `AgentCoreShortTermMemoryRepository`
- **`spring-ai-agentcore-bom`** — version alignment across all SDK modules

---

## Prerequisites

These are shared across all examples:

- **Java 25** (Java 21 for `product-catalog-service`)
- **Maven wrapper** (`./mvnw`) included in each module — no global Maven installation required
- **SAP AI Core service key** — BTP service binding or environment variables (`AICORE_AUTH_URL`, `AICORE_CLIENT_ID`, `AICORE_CLIENT_SECRET`, `AICORE_RESOURCE_GROUP`, `AICORE_BASE_URL`)
- **SAP S/4HANA Public Cloud API key** — set as `SAP_S4HANA_PUBLIC_CLOUD_KEY` environment variable
- **AWS CLI configured** — required for AgentCore deployment examples (examples 5–9)
- **Docker** — required for deployment examples (examples 5–9)

---

## Examples

The examples form a progression where each builds on the previous:

| # | Directory | What it demonstrates |
|---|---|---|
| 1 | `sapaiagent-with-prompttemplate-masking` | SAP AI SDK basics: prompt templating + DPI masking (anonymization/pseudonymization) |
| 2 | `sapsupplychainagent-using-chain-workflow-pattern` | 3-step sequential chain workflow for SAP supply chain queries |
| 3 | `sapsupplychainagent-using-orchestrator-workers-pattern` | Orchestrator-workers pattern with parallel worker execution |
| 4 | `product-catalog-service` | Supporting Lambda service — Spring Boot on AWS Lambda + SnapStart |
| 5 | `sapsupplychainagent-with-gui-agentcore-deployment` | Deploy chain workflow agent to AWS AgentCore with GUI (Cognito + CloudFront) |
| 6 | `sapsupplychainagent-with-gui-agentcore-observability` | Add full OTEL/X-Ray observability (ADOT Java agent, GenAI semantic conventions) |
| 7 | `sapsupplychainagent-with-gui-agentcore-memory` | Add persistent AgentCore Memory (STM + LTM with fact/preference extraction) |
| 8 | `sapsupplychainagent-with-agentcore-gateway` | Add AgentCore Gateway — MCP over OAuth2 to expose Product Catalog |
| 9 | `sapsupplychainagent-with-agentcore-a2a-multi-agent` | Distributed multi-agent A2A system: 5 independently deployed agents |

Each example directory contains its own detailed README with setup instructions, architecture notes, and deployment steps.

---

## Quick start (run locally without AWS)

Examples 1 and 2 require only SAP AI Core credentials — no AWS account or Docker needed:

```bash
# Example 1 — prompt templating + DPI masking
cd examples/sapaiagent-with-prompttemplate-masking
./mvnw spring-boot:run

# Example 2 — chain workflow
cd examples/sapsupplychainagent-using-chain-workflow-pattern
./mvnw spring-boot:run
```

---

## Repository structure

```
examples/
├── sapaiagent-with-prompttemplate-masking/
├── sapsupplychainagent-using-chain-workflow-pattern/
├── sapsupplychainagent-using-orchestrator-workers-pattern/
├── product-catalog-service/
├── sapsupplychainagent-with-gui-agentcore-deployment/
├── sapsupplychainagent-with-gui-agentcore-observability/
├── sapsupplychainagent-with-gui-agentcore-memory/
├── sapsupplychainagent-with-agentcore-gateway/
└── sapsupplychainagent-with-agentcore-a2a-multi-agent/
```

---

## Tech stack

| Component | Version |
|---|---|
| Java | 25 (21 for product-catalog-service) |
| Spring Boot | 3.5.11 |
| Spring AI | 1.1.2 |
| SAP AI SDK | 1.16.0 |
| Spring AI AgentCore SDK | 1.0.0 |
| Model | claude-sonnet-4-5 (via SAP GenAI Hub) |

---

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

