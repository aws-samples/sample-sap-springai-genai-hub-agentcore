# Product Catalog Service

A standalone Spring Boot REST service that acts as the **MCP server backend** for the [`sapsupplychainagent-with-agentcore-gateway`](../sapsupplychainagent-with-agentcore-gateway) example. It is deployed as an AWS Lambda function behind API Gateway and registered as an AgentCore Gateway target via its OpenAPI spec.

---

## Architecture

```
   Client
     │  x-api-key header
     ▼
┌──────────────────────┐
│   AWS API Gateway    │
│   (REST, REGIONAL)   │
│   API key auth       │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  AWS Lambda          │
│  Java 21 + SnapStart │
│  StreamLambdaHandler │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────────────────────┐
│        Spring Boot Application       │
│                                      │
│  ProductCatalogController            │
│  GET|POST|PUT|DELETE /products       │
│  GET /v3/api-docs  ◄── used by       │
│                        gateway ex.   │
│           │                          │
│           ▼                          │
│  ProductCatalogService               │
│  (in-memory store, 5 seeded items)   │
└──────────────────────────────────────┘
```

---

## Stack

| Component | Version |
|---|---|
| Java | 21 (Lambda runtime) |
| Spring Boot | 3.5.11 |
| AWS Serverless Java Container | Lambda proxy handler |
| Lambda SnapStart | `PublishedVersions` |
| API Gateway | REST API (REGIONAL), stage `prod` |

---

## API

| Method | Path | Description |
|---|---|---|
| `GET` | `/products` | List all products |
| `POST` | `/products` | Create a product |
| `GET` | `/products/{id}` | Get a product by ID |
| `PUT` | `/products/{id}` | Update a product |
| `DELETE` | `/products/{id}` | Delete a product |
| `GET` | `/products/search?category=&name=` | Search products |
| `GET` | `/v3/api-docs` | OpenAPI spec (used by gateway registration) |
| `GET` | `/swagger-ui.html` | Swagger UI |

When deployed, API key authentication is enforced at the **API Gateway layer** (`x-api-key` header). Locally, no API key is required.

### Sample seeded products

The service starts with 5 industrial products pre-loaded in memory:

| ID | Name | Category |
|---|---|---|
| 1 | Industrial Conveyor Belt | Material Handling |
| 2 | Hydraulic Press 50T | Manufacturing Equipment |
| 3 | Safety Helmet Class E | Personal Protective Equipment |
| 4 | Pneumatic Drill | Power Tools |
| 5 | Chemical Resistant Gloves | Personal Protective Equipment |

---

## Project Structure

```
product-catalog-service/
├── src/main/java/com/example/productcatalog/
│   ├── ProductCatalogApplication.java
│   ├── StreamLambdaHandler.java              # AWS Lambda entry point
│   ├── controller/ProductCatalogController.java  # REST endpoints
│   ├── model/Product.java
│   └── service/ProductCatalogService.java    # In-memory store (seeded at startup)
└── deploy/
    └── cloudformation/
        ├── .env.example
        ├── infra.yaml    # Lambda + SnapStart + API Gateway + API key auth
        ├── deploy.sh
        └── cleanup.sh
```

---

## Prerequisites

- AWS CLI configured with permissions for Lambda, API Gateway, IAM, S3
- Maven wrapper (`./mvnw`) included

---

## Build & Run

> **This service cannot be run locally.** Tomcat is intentionally excluded from the build because the JAR is packaged for AWS Lambda using `aws-serverless-java-container`. Running `./mvnw spring-boot:run` will exit immediately — there is no embedded web server.
>
> To test this service, deploy it to AWS first (see [Deploy to AWS](#deploy-to-aws-cloudformation) below) and use the AWS CLI commands in the [Test](#3--test) section.

You can still build the JAR to verify compilation:

```bash
cd examples/product-catalog-service
./mvnw clean package -DskipTests
```

---

## Deploy to AWS (CloudFormation)

Deploys the service as a Lambda function (Java 21 + SnapStart) behind API Gateway.

### 1 — Configure

```bash
cd examples/product-catalog-service
cp deploy/cloudformation/.env.example deploy/cloudformation/.env
# Edit deploy/cloudformation/.env — set PRODUCT_CATALOG_API_KEY
```

### 2 — Deploy

```bash
./deploy/cloudformation/deploy.sh
```

The script runs automatically:

| Step | Action |
|---|---|
| 1 | Build the JAR (`./mvnw clean package -DskipTests`) |
| 2 | Create a staging S3 bucket and upload the JAR |
| 3 | Deploy CloudFormation stack (Lambda + SnapStart version/alias, API Gateway, IAM role) |
| 4 | Smoke test — `GET /products` must return HTTP 200 |

On completion the script prints:

```
 Product Catalog URL: https://<api-id>.execute-api.<region>.amazonaws.com/prod
```

Copy this URL — it is the `PRODUCT_CATALOG_URL` required by the gateway example.

### 3 — Test

```bash
source deploy/cloudformation/.runtime-state

curl -H "x-api-key: $PRODUCT_CATALOG_API_KEY" "${PRODUCT_CATALOG_URL}/products"
curl -H "x-api-key: $PRODUCT_CATALOG_API_KEY" "${PRODUCT_CATALOG_URL}/v3/api-docs" | jq .info.title
```

### 4 — Cleanup

```bash
./deploy/cloudformation/cleanup.sh
```

Cleanup deletes the CloudFormation stack (Lambda, API Gateway, IAM role) and the S3 staging bucket.

---

## Notes

- The service uses an **in-memory store** — data resets on Lambda cold starts. This is intentional for a demo service.
- **Lambda SnapStart** reduces cold start latency for the Java runtime. The CloudFormation template publishes a new Lambda version on each deploy and points the `live` alias at it.
- The staging S3 bucket (`${PROJECT_NAME}-staging-${AWS_ACCOUNT_ID}`) is created outside CloudFormation since Lambda deployment requires the JAR in S3 before the stack can be deployed.
- The OpenAPI spec at `/v3/api-docs` is used by the gateway example's `deploy.sh` to register the product catalog as an AgentCore Gateway MCP target.
