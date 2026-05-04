# SAP AI Agent — Prompt Templating & DPI Masking

A standalone Spring Boot example demonstrating **prompt templating** and **DPI (Data Protection & Privacy) masking** using the [SAP AI SDK](https://github.com/SAP/ai-sdk-java) with Spring AI, backed by Amazon Bedrock via SAP GenAI Hub.

Three orchestration features are available through a single streaming endpoint, selectable via the `mode` field.

---

## Architecture

```
   Client
     │  POST /chatStream { prompt, mode, language }
     ▼
┌────────────────────────────────────────────────────────────┐
│                   Spring Boot Application                  │
│                                                            │
│  InvocationController                                      │
│       │                                                    │
│       ▼                                                    │
│  SAPAIOrchestrationService                                 │
│       │                                                    │
│       ├─ mode: BASIC                                       │
│       ├─ mode: PROMPT_TEMPLATE (customer-support)          │
│       ├─ mode: MASKING_ANONYMIZATION (DPI one-way)         │
│       └─ mode: MASKING_PSEUDONYMIZATION (DPI reversible)   │
└────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌──────────────────────────────────┐
              │  SAP GenAI Hub                   │
              │  Orchestration API               │
              │  ┌──────────────────────────┐    │
              │  │   DPI Masking Module     │    │
              │  │  (anonymize/pseudo.)     │    │
              │  └──────────────────────────┘    │
              └───────────────┬──────────────────┘
                              │
                              ▼
              ┌──────────────────────────────────┐
              │       Amazon Bedrock             │
              │    (claude-4-5-sonnet)           │
              └──────────────────────────────────┘
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

---

## Project Structure

```
src/main/
├── java/com/example/sapaiagent/
│   ├── SapaiagentApplication.java
│   ├── controller/
│   │   └── InvocationController.java       # POST /chatStream
│   ├── model/
│   │   ├── ChatMode.java                   # Enum: BASIC | PROMPT_TEMPLATE | MASKING_ANONYMIZATION | MASKING_PSEUDONYMIZATION
│   │   └── InvocationRequest.java
│   └── service/
│       └── SAPAIOrchestrationService.java  # Routing and feature implementations
└── resources/
    ├── application.properties
    └── prompttemplates/
        └── customer-support-prompt-template.txt
```

---

## API

### `POST /chatStream`

| Field | Type | Required | Description |
|---|---|---|---|
| `prompt` | `String` | Yes | User input |
| `language` | `String` | No | Response language for `PROMPT_TEMPLATE` mode — defaults to `English` |
| `mode` | `ChatMode` | No | Feature to demonstrate — defaults to `BASIC` |

| Mode | Description |
|---|---|
| `BASIC` | Plain streaming chat with no additional configuration |
| `PROMPT_TEMPLATE` | Fills an externalized customer support template with `{prompt}` and `{language}` placeholders |
| `MASKING_ANONYMIZATION` | PII replaced with generic tokens (e.g. `MASKED_EMAIL`) before reaching the LLM — permanent, one-way |
| `MASKING_PSEUDONYMIZATION` | PII replaced with numbered tokens (e.g. `MASKED_PERSON_1`) before the LLM, then reversed in the response — two-way |

```bash
# Basic chat
curl -X POST http://localhost:9090/chatStream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Tell me about Spring AI"}'

# Prompt template — respond in German
curl -X POST http://localhost:9090/chatStream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "I cannot log into my account.", "language": "German", "mode": "PROMPT_TEMPLATE"}'

# DPI anonymization — PII replaced with generic tokens
curl -X POST http://localhost:9090/chatStream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Feedback from John Smith (john.smith@example.com, +1-555-0100): Great service!", "mode": "MASKING_ANONYMIZATION"}'

# DPI pseudonymization — PII replaced with numbered tokens, reversed in response
curl -X POST http://localhost:9090/chatStream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Username: Alice, Email: alice@example.com. Colleague Bob (bob@example.com) agrees.", "mode": "MASKING_PSEUDONYMIZATION"}'
```

---

## Prerequisites

- **SAP AI Core service key** (`AICORE_SERVICE_KEY`) — create in SAP BTP following the [SAP AI Core service key guide](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key)

> **Security note — `.env` file**
>
> The `.env` file is gitignored and must never be committed. It contains `AICORE_SERVICE_KEY`, a full SAP BTP service key JSON that grants access to SAP AI Core. This is provided for local convenience in this sample only.
>
> For more secure alternatives:
> - **Export variables directly** — set `AICORE_SERVICE_KEY` as a shell environment variable in your terminal before running `./mvnw spring-boot:run`; the `.env` file and the export one-liner are not needed if the variable is already set.
> - **SAP AI SDK service binding** — the SAP Cloud SDK for AI supports providing the service binding via `VCAP_SERVICES` or a local `default-env.json` file: [Providing a Service Binding Locally](https://sap.github.io/ai-sdk/docs/java/connecting-to-ai-core#providing-a-service-binding-locally)

---

## Environment Variables

| Variable | Description |
|---|---|
| `AICORE_SERVICE_KEY` | SAP AI Core service key JSON — [create in SAP BTP](https://help.sap.com/docs/sap-ai-core/sap-ai-core-service-guide/create-service-key) |

---

## Build & Run

```bash
cd examples/sapaiagent-with-prompttemplate-masking
cp .env.example .env
# Edit .env — replace AICORE_SERVICE_KEY with your real value
while IFS= read -r line; do [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue; export "$line"; done < .env
./mvnw spring-boot:run   # default port: 9090
```
