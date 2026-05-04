# SAP Supply Chain Agent — Orchestrator-Workers Pattern

Demonstrates the **orchestrator-workers agentic pattern** for answering complex, multi-domain supply chain queries. An orchestrator LLM breaks the query into typed worker tasks, workers execute in parallel, and a synthesis step merges the results into a final answer.

---

## Architecture

```
   Client
     │  POST /invocations { prompt }
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Spring Boot Application                     │
│                                                                 │
│  InvocationController ──► OrchestratorWorkersService           │
│                                    │                            │
│                                    ▼                            │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Orchestrator  [toolOptions]                              │   │
│  │  Decomposes query → JSON task list                        │   │
│  │  Simple queries → [FINAL] short-circuit                   │   │
│  └─────────────────────┬────────────────────────────────────┘   │
│                        │ task list                               │
│                        ▼ parallel (CompletableFuture, 4 threads) │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────┐  ┌───────┐  │
│  │  SAP Worker  │  │ Weather Worker│  │DateTime W│  │AWS W. │  │
│  │ selectApi +  │  │ getWeather    │  │getDateTime│  │MCP KB │  │
│  │ executeApi   │  │ Forecast      │  │           │  │tools  │  │
│  └──────┬───────┘  └───────┬───────┘  └────┬─────┘  └──┬────┘  │
│         └──────────────────┴───────────────┴────────────┘       │
│                                    │ worker results               │
│                                    ▼                              │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Synthesis  [textOnlyOptions]                            │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
           │ each LLM call
           ▼
SAP S/4HANA OData API · SAP GenAI Hub (claude-4-5-sonnet via Bedrock)
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
│   └── InvocationController.java          # POST /invocations
├── model/
│   ├── InvocationRequest.java
│   └── SAPOdataAPISpec.java
└── service/
    ├── SAPAIOrchestrationService.java      # Entry point — delegates to OrchestratorWorkersService
    ├── OrchestratorWorkersService.java     # Orchestrator + parallel workers + synthesis
    ├── SAPOdataApiSpecLoader.java
    ├── SAPOdataApiSelectorTool.java        # @Tool: selectApi
    ├── SAPApiExecutorTool.java             # @Tool: executeApi
    ├── DateTimeTools.java                  # @Tool: getCurrentDateTime
    └── WeatherTools.java                   # @Tool: getWeatherForecast
```

---

## How It Works

```
User Request
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│ Orchestrator LLM  (toolOptions)                                 │
│ Analyzes the query and returns a JSON task list:                │
│ [{"id":"...", "worker":"SAP Worker", "description":"..."},...]  │
│                                                                 │
│ Simple queries (no workers needed) answered directly with       │
│ [FINAL] prefix → short-circuit, no workers dispatched.         │
└──────────────────────────────┬──────────────────────────────────┘
                               │ task list
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ Workers — parallel execution via CompletableFuture (4-thread)   │
│                                                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  ┌───────┐ │
│  │ SAP Worker  │  │Weather Worker│  │DateTime W. │  │AWS W. │ │
│  │ selectApi + │  │getWeather    │  │getDateTime │  │MCP    │ │
│  │ executeApi  │  │Forecast      │  │            │  │tools  │ │
│  └─────────────┘  └──────────────┘  └────────────┘  └───────┘ │
└──────────────────────────────┬──────────────────────────────────┘
                               │ worker results
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ Synthesis  (textOnlyOptions — no tool schemas)                  │
│ Merges all worker outputs into a single coherent response.      │
└─────────────────────────────────────────────────────────────────┘
```

### Available Workers

| Worker | Tools used | Handles |
|---|---|---|
| SAP Worker | `selectApi`, `executeApi` | Freight, inventory, warehouse, supply chain |
| Weather Worker | `getWeatherForecast` | Weather forecasts and conditions |
| DateTime Worker | `getCurrentDateTime` | Date and time queries |
| AWS Worker | MCP AWS Knowledge Base tools | AWS services, best practices, architecture |

### Two-Options Pattern

| Options | Used in | Tool schemas included |
|---|---|---|
| `toolOptions` | Orchestrator + Workers | Yes |
| `textOnlyOptions` | Synthesis | No — faster, lower token overhead |

### Per-Step Conversation IDs

The orchestrator, each worker, and synthesis use distinct conversation IDs (e.g. `alice-orchestrator`, `alice-worker-sap1`, `alice-synthesis`) to isolate conversation histories and avoid SAP AI Core rejecting assistant messages that contain only tool invocation blocks.

### Short-Circuit for Simple Queries

If the orchestrator determines no workers are needed, it prefixes its response with `[FINAL]` and the workflow returns immediately — no workers are dispatched.

---

## API

### `POST /invocations`

| Element | Detail |
|---|---|
| Body | `{"prompt": "..."}` |
| Header | `Authorization: <username>` — used as conversation ID prefix |
| Response | Plain text (`text/plain`) |

```bash
# Multi-domain query — dispatches SAP + Weather workers in parallel
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -H "Authorization: alice" \
  -d '{"prompt": "Show open freight orders for next week and check the weather in Hamburg"}'

# Single-domain SAP query — dispatches only SAP worker
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -H "Authorization: alice" \
  -d '{"prompt": "What inventory items are low in stock?"}'

# Simple query — short-circuits, no workers
curl -X POST http://localhost:9090/invocations \
  -H "Content-Type: application/json" \
  -H "Authorization: alice" \
  -d '{"prompt": "Hello, how are you?"}'
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
cd examples/sapsupplychainagent-using-orchestrator-workers-pattern
cp .env.example .env
# Edit .env — replace AICORE_SERVICE_KEY and SAP_S4HANA_PUBLIC_CLOUD_KEY with your real values
while IFS= read -r line; do [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue; export "$line"; done < .env
./mvnw spring-boot:run   # default port: 9090
```

---

## References

- [Building Effective Agents — Anthropic Engineering](https://www.anthropic.com/engineering/building-effective-agents)
