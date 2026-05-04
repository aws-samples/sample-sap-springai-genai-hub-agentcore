# SAP Supply Chain Agent — Chain Workflow Pattern

Demonstrates a **3-step sequential chain workflow** for answering SAP supply chain queries. Each step has a distinct role — query analysis, SAP OData API execution, and response formatting — with differentiated tool configurations per step for performance.

---

## Architecture

```
   Client
     │  POST /invocations { prompt }
     ▼
┌─────────────────────────────────────────────────────────────┐
│                   Spring Boot Application                   │
│                                                             │
│  InvocationController ──► SAPAIOrchestrationService        │
│                                    │                        │
│                                    ▼                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               ChainWorkflowService                  │   │
│  │                                                     │   │
│  │  Step 1 — Analyze & Select  [toolOptions]           │   │
│  │  ┌────────────┐ ┌──────────────┐ ┌───────────────┐ │   │
│  │  │ selectApi  │ │ getDateTime  │ │ getWeather    │ │   │
│  │  └────────────┘ └──────────────┘ └───────────────┘ │   │
│  │       │ non-SAP → [FINAL] short-circuit             │   │
│  │       ▼ SAP query                                   │   │
│  │  Step 2 — Execute SAP API  [toolOptions]            │   │
│  │  ┌─────────────┐                                    │   │
│  │  │ executeApi  │──► SAP S/4HANA OData API           │   │
│  │  └─────────────┘    (sandbox.api.sap.com)           │   │
│  │       ▼                                             │   │
│  │  Step 3 — Format Response  [textOnlyOptions]        │   │
│  │  MessageChatMemoryAdvisor (InMemoryChatMemory)      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  MCP: AWS Knowledge Base (knowledge-mcp.global.api.aws)    │
└─────────────────────────────────────────────────────────────┘
                          │ each step
                          ▼
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
| Model | `claude-4-5-sonnet` |
| MCP Server | AWS Knowledge Base (`knowledge-mcp.global.api.aws`) |

---

## Project Structure

```
src/main/java/com/example/sapaiagent/
├── SapaiagentApplication.java
├── controller/
│   └── InvocationController.java         # POST /invocations
├── model/
│   ├── InvocationRequest.java
│   └── SAPOdataAPISpec.java               # OpenAPI spec metadata
└── service/
    ├── SAPAIOrchestrationService.java     # Entry point — delegates to ChainWorkflowService
    ├── ChainWorkflowService.java          # 3-step chain orchestration
    ├── SAPOdataApiSpecLoader.java         # Loads OpenAPI specs from classpath
    ├── SAPOdataApiSelectorTool.java       # @Tool: selectApi
    ├── SAPApiExecutorTool.java            # @Tool: executeApi
    ├── DateTimeTools.java                 # @Tool: getCurrentDateTime
    └── WeatherTools.java                  # @Tool: getWeatherForecast
```

---

## How It Works

```
User Request
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 1 — Analyze & Select  (toolOptions)                    │
│ LLM calls selectApi to identify the SAP endpoint needed.    │
│ Also calls weather/datetime tools if relevant.              │
│ Non-SAP queries answered directly with [FINAL] prefix       │
│ → short-circuits, skips Steps 2 & 3.                        │
└────────────────────────┬────────────────────────────────────┘
                         │ SAP query
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 2 — Execute SAP API  (toolOptions)                     │
│ LLM extracts apiTitle, baseUrl, endpoint from Step 1 output │
│ and calls executeApi to fetch live OData data.              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ Step 3 — Format Response  (textOnlyOptions — no tools)      │
│ LLM combines SAP data + any weather/date context and        │
│ formats a clean, concise final answer.                      │
└─────────────────────────────────────────────────────────────┘
```

### Two-Options Pattern

| Options | Used in | Tool schemas included |
|---|---|---|
| `toolOptions` | Steps 1 & 2 | Yes — LLM can invoke tools |
| `textOnlyOptions` | Step 3 | No — pure formatting, lower token overhead |

### Memory Management

A single `MessageChatMemoryAdvisor` (backed by `InMemoryChatMemoryRepository`) is used, keyed by `username`. The advisor is attached **only on Step 3** (the text-only formatting step). Steps 1 and 2 are excluded because the LLM may produce tool-call-only assistant messages with no text content, which causes issues when the message is replayed as conversation history.

For short-circuited non-SAP queries (Step 1 answers directly), the memory advisor is attached on Step 1 instead so the exchange is still persisted.

### Short-Circuit for Non-SAP Queries

If Step 1 determines no SAP data is needed (greetings, weather, datetime, AWS questions), it prefixes its answer with `[FINAL]` and the chain returns immediately without running Steps 2 or 3.

---

## API

### `POST /invocations`

| Element | Detail |
|---|---|
| Body | `{"prompt": "..."}` |
| Header | `Authorization: <username>` — used as the conversation ID |
| Response | Plain text (`text/plain`) |

```bash
# SAP supply chain query — runs all 3 steps
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -H "Authorization: alice" \
  -d '{"prompt": "Show me open freight orders for next week"}'

# Non-SAP query — short-circuits after Step 1
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -H "Authorization: alice" \
  -d '{"prompt": "What is the weather in Hamburg tomorrow?"}'
```

---

## Prerequisites

- **SAP AI Core service key** (`AICORE_SERVICE_KEY`) — create in SAP BTP following the [SAP AI Core service key guide](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)
- **SAP S/4HANA Public Cloud API key** (`SAP_S4HANA_PUBLIC_CLOUD_KEY`) — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key**

> **Security note — `.env` file**
>
> The `.env` file is gitignored and must never be committed. It contains `AICORE_SERVICE_KEY`, a full SAP BTP service key JSON that grants access to SAP AI Core. This is provided for local convenience in this sample only.
>
> For more secure alternatives:
> - **Export variables directly** — set `AICORE_SERVICE_KEY` and `SAP_S4HANA_PUBLIC_CLOUD_KEY` as shell environment variables in your terminal before running `./mvnw spring-boot:run`; the `.env` file and the export one-liner are not needed if the variables are already set.
> - **SAP AI SDK service binding** — the SAP Cloud SDK for AI supports providing the service binding via `VCAP_SERVICES` or a local `default-env.json` file: [Providing a Service Binding Locally](https://sap.github.io/ai-sdk/docs/java/connecting-to-ai-core#providing-a-service-binding-locally)

---

## Environment Variables

| Variable | Description |
|---|---|
| `AICORE_SERVICE_KEY` | SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key) |
| `SAP_S4HANA_PUBLIC_CLOUD_KEY` | SAP S/4HANA Public Cloud sandbox API key — log on at [SAP API Business Hub](https://api.sap.com/api/CE_WHSEPHYSICALSTOCKPRODUCTS_0001/tryout) and click **Show API Key** |

---

## Build & Run

```bash
cd examples/sapsupplychainagent-using-chain-workflow-pattern
cp .env.example .env
# Edit .env — replace AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY with your real values
while IFS= read -r line; do [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue; export "$line"; done < .env
./mvnw spring-boot:run   # default port: 9090
```

---

## References

- [Building Effective Agents — Anthropic Engineering](https://www.anthropic.com/engineering/building-effective-agents)
