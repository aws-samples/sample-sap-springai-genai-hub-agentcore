#!/usr/bin/env bash
# ===================================================================
# deploy.sh — Deploy SAP AI Agent (with gateway) to AWS AgentCore
#
# Prerequisites:
#   - Deploy product-catalog-service first and note its URL
#
# Usage:
#   cp deploy/cloudformation/.env.example deploy/cloudformation/.env
#   # Edit .env with your values
#   ./deploy/cloudformation/deploy.sh
# ===================================================================
set -euo pipefail

cleanup_temp_files() { rm -f /tmp/env-vars.json /tmp/gui-config.json; }
trap cleanup_temp_files EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env safely (avoids shell expansion of $, !, | etc. in JSON values)
# SECURITY NOTE: The .env file is provided for local convenience in this sample only.
# It must never be committed. For more secure alternatives, see the README:
#   - Export AICORE_SERVICE_KEY / SAP_S4HANA_PUBLIC_CLOUD_KEY directly as shell env vars
#     before running this script; the .env file is skipped if variables are already set.
#   - SAP AI SDK service binding: https://sap.github.io/ai-sdk/docs/java/connecting-to-ai-core#providing-a-service-binding-locally
#   - AWS Secrets Manager: retrieve the secret via `aws secretsmanager get-secret-value`
load_env() {
    local env_file="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        local key="${line%%=*}"
        local val="${line#*=}"
        [ "$key" = "$line" ] && continue
        [ -z "$key" ] && continue
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        [ -n "${!key+x}" ] || export "$key=$val"
    done < "$env_file"
}
if [ -f "$SCRIPT_DIR/.env" ]; then
    load_env "$SCRIPT_DIR/.env"
fi

# ===================================================================
# Preflight: verify Docker daemon is running
# ===================================================================
if ! docker info >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Docker daemon is not running."
    echo "       Start Docker Desktop (or your Docker daemon) and retry."
    echo "       The deployment requires Docker to build and push the container image to ECR."
    echo ""
    exit 1
fi

# ===================================================================
# Configuration
# ===================================================================
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
PROJECT_NAME="${PROJECT_NAME:-sapaiagent-gateway}"
CF_STACK_NAME="${PROJECT_NAME}-infra"
IMAGE_TAG="${IMAGE_TAG:-latest}"
RUNTIME_NAME="${PROJECT_NAME//-/_}_runtime"
MEMORY_NAME="${PROJECT_NAME//-/_}_memory"
GATEWAY_NAME="sapaiagent-tools-gateway"
CREDENTIAL_PROVIDER_NAME="${PROJECT_NAME}-catalog-apikey"
TARGET_NAME="${PROJECT_NAME}-catalog-target"

: "${AICORE_SERVICE_KEY:?Set AICORE_SERVICE_KEY in deploy/cloudformation/.env}"
: "${SAP_S4HANA_PUBLIC_CLOUD_KEY:?Set SAP_S4HANA_PUBLIC_CLOUD_KEY in deploy/cloudformation/.env}"
: "${PRODUCT_CATALOG_URL:?Set PRODUCT_CATALOG_URL in deploy/cloudformation/.env}"
: "${PRODUCT_CATALOG_API_KEY:?Set PRODUCT_CATALOG_API_KEY in deploy/cloudformation/.env}"

echo "================================================================="
echo " SAP AI Agent — AgentCore Gateway"
echo " Region:   $AWS_REGION"
echo " Account:  $AWS_ACCOUNT_ID"
echo " Project:  $PROJECT_NAME"
echo "================================================================="

# ===================================================================
# Step 0: X-Ray Transaction Search (idempotent)
# ===================================================================
echo ""
echo ">>> Step 0: Configuring X-Ray Transaction Search..."
aws xray update-trace-segment-destination \
    --destination CloudWatchLogs \
    --region "$AWS_REGION" 2>/dev/null || true
aws xray update-indexing-rule \
    --name "Default" \
    --rule '{"Probabilistic":{"DesiredSamplingPercentage":1}}' \
    --region "$AWS_REGION" 2>/dev/null || true
echo "  X-Ray configured."

# ===================================================================
# Step 1: Deploy CloudFormation
# ===================================================================
echo ""
echo ">>> Step 1: Deploying infrastructure (CloudFormation)..."

# If a previous deployment left the stack in a non-updatable state, delete it
# first so we can redeploy cleanly. Affected states:
#   ROLLBACK_COMPLETE       — create failed and rolled back (cannot be updated)
#   CREATE_FAILED           — create failed with rollback disabled
#   DELETE_FAILED           — previous cleanup left a half-deleted stack
#   UPDATE_ROLLBACK_FAILED  — update rollback stuck (needs manual deletion)
STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$CF_STACK_NAME" \
    --query "Stacks[0].StackStatus" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "DOES_NOT_EXIST")
case "$STACK_STATUS" in
    ROLLBACK_COMPLETE|CREATE_FAILED|DELETE_FAILED|UPDATE_ROLLBACK_FAILED|ROLLBACK_FAILED)
        echo "  Stack is in $STACK_STATUS state. Deleting before re-deploying..."
        aws cloudformation delete-stack --stack-name "$CF_STACK_NAME" --region "$AWS_REGION"
        aws cloudformation wait stack-delete-complete --stack-name "$CF_STACK_NAME" --region "$AWS_REGION"
        echo "  Stack deleted. Proceeding with fresh deployment..."
        ;;
esac

aws cloudformation deploy \
    --template-file "$SCRIPT_DIR/infra.yaml" \
    --stack-name "$CF_STACK_NAME" \
    --parameter-overrides ProjectName="$PROJECT_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --region "$AWS_REGION"

read_output() {
    aws cloudformation describe-stacks \
        --stack-name "$CF_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
        --output text --region "$AWS_REGION"
}

ECR_URI=$(read_output EcrRepositoryUri)
EXECUTION_ROLE_ARN=$(read_output ExecutionRoleArn)
GATEWAY_ROLE_NAME=$(read_output GatewayRoleName)
GATEWAY_ROLE_ARN=$(read_output GatewayRoleArn)
USER_POOL_ID=$(read_output UserPoolId)
APP_CLIENT_ID=$(read_output AppClientId)
COGNITO_DISCOVERY=$(read_output CognitoDiscoveryUrl)
TOKEN_ENDPOINT=$(read_output CognitoTokenEndpoint)
GUI_BUCKET=$(read_output GuiBucketName)
CF_DIST_ID=$(read_output CloudFrontDistributionId)
CF_DOMAIN=$(read_output CloudFrontDomain)

echo "ECR:            $ECR_URI"
echo "Gateway role:   $GATEWAY_ROLE_ARN"
echo "Cognito pool:   $USER_POOL_ID / client: $APP_CLIENT_ID"

# ===================================================================
# Step 2: Create/reuse AgentCore Memory
# ===================================================================
echo ""
echo ">>> Step 2: Setting up AgentCore Memory..."

AGENTCORE_MEMORY_MEMORY_ID=""

# Idempotency: check .runtime-state first, then scan list-memories by ID prefix
# (Memory IDs are always "{name}-{10chars}", so prefix match is reliable)
if [ -f "$SCRIPT_DIR/.runtime-state" ]; then
    SAVED_MEM_ID=$(grep "^AGENTCORE_MEMORY_MEMORY_ID=" "$SCRIPT_DIR/.runtime-state" | cut -d= -f2 || echo "")
    if [ -n "$SAVED_MEM_ID" ]; then
        MEM_STATUS=$(aws bedrock-agentcore-control get-memory \
            --memory-id "$SAVED_MEM_ID" \
            --region "$AWS_REGION" \
            --query 'memory.status' --output text 2>/dev/null || echo "NOT_FOUND")
        if [ "$MEM_STATUS" = "ACTIVE" ]; then
            echo "  Reusing existing memory: $SAVED_MEM_ID"
            AGENTCORE_MEMORY_MEMORY_ID="$SAVED_MEM_ID"
        fi
    fi
fi

if [ -z "$AGENTCORE_MEMORY_MEMORY_ID" ]; then
    FOUND_ID=$(aws bedrock-agentcore-control list-memories \
        --region "$AWS_REGION" \
        --query "memories[].id" \
        --output text 2>/dev/null | tr '\t' '\n' | grep "^${MEMORY_NAME}-" | head -1 || echo "")
    if [ -n "$FOUND_ID" ]; then
        echo "  Found existing memory by name: $FOUND_ID"
        AGENTCORE_MEMORY_MEMORY_ID="$FOUND_ID"
    fi
fi

if [ -z "$AGENTCORE_MEMORY_MEMORY_ID" ]; then
    echo "  Creating memory resource: $MEMORY_NAME"
    STRATEGIES=$(mktemp)
    cat > "$STRATEGIES" <<'EOF'
[{"semanticMemoryStrategy":{"name":"facts","namespaces":["/strategies/{memoryStrategyId}/actors/{actorId}/"]}},{"userPreferenceMemoryStrategy":{"name":"prefs","namespaces":["/strategies/{memoryStrategyId}/actors/{actorId}/"]}}]
EOF
    MEMORY_RESPONSE=$(aws bedrock-agentcore-control create-memory \
        --name "$MEMORY_NAME" \
        --description "SAP AI Agent — conversation memory" \
        --event-expiry-duration 90 \
        --memory-strategies "file://${STRATEGIES}" \
        --region "$AWS_REGION")
    rm -f "$STRATEGIES"
    AGENTCORE_MEMORY_MEMORY_ID=$(echo "$MEMORY_RESPONSE" | jq -r '.memory.id')

    echo "  Waiting for memory to become ACTIVE..."
    while true; do
        STATUS=$(aws bedrock-agentcore-control get-memory \
            --memory-id "$AGENTCORE_MEMORY_MEMORY_ID" \
            --region "$AWS_REGION" --query 'memory.status' --output text)
        echo "    Status: $STATUS"
        if [ "$STATUS" = "ACTIVE" ]; then break; fi
        if [ "$STATUS" = "FAILED" ]; then echo "ERROR: Memory creation failed"; exit 1; fi
        sleep 10
    done
fi

# ===================================================================
# Step 3: Setup AgentCore Gateway
# ===================================================================
echo ""
echo ">>> Step 3: Setting up AgentCore Gateway..."

# 3a. Create/reuse API key credential provider
EXISTING_CRED_ARN=$(aws bedrock-agentcore-control get-api-key-credential-provider \
    --name "$CREDENTIAL_PROVIDER_NAME" \
    --region "$AWS_REGION" \
    --query 'credentialProviderArn' --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CRED_ARN" ] && [ "$EXISTING_CRED_ARN" != "None" ]; then
    echo "  Reusing credential provider: $EXISTING_CRED_ARN"
    CREDENTIAL_PROVIDER_ARN="$EXISTING_CRED_ARN"
else
    echo "  Creating API key credential provider: $CREDENTIAL_PROVIDER_NAME"
    CRED_RESPONSE=$(aws bedrock-agentcore-control create-api-key-credential-provider \
        --name "$CREDENTIAL_PROVIDER_NAME" \
        --api-key "$PRODUCT_CATALOG_API_KEY" \
        --region "$AWS_REGION" --no-cli-pager)
    CREDENTIAL_PROVIDER_ARN=$(echo "$CRED_RESPONSE" | jq -r '.credentialProviderArn')
    echo "  Created: $CREDENTIAL_PROVIDER_ARN"
fi

# 3b. Attach inline policy to gateway role (Secrets Manager + AgentCore)
SECRET_ARN=$(aws bedrock-agentcore-control get-api-key-credential-provider \
    --name "$CREDENTIAL_PROVIDER_NAME" \
    --region "$AWS_REGION" \
    --query 'apiKeySecretArn.secretArn' --output text)

# Gateway role is assumed by the AgentCore Gateway service at runtime (not by deploy/cleanup scripts).
# Scoped to read-only gateway config + credential retrieval + agent invocation.
cat > /tmp/gateway-policy.json <<EOFPOL
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"${SECRET_ARN}"},
    {"Effect":"Allow","Action":[
      "bedrock-agentcore:GetGateway",
      "bedrock-agentcore:ListGateways",
      "bedrock-agentcore:GetGatewayTarget",
      "bedrock-agentcore:ListGatewayTargets",
      "bedrock-agentcore:GetApiKeyCredentialProvider",
      "bedrock-agentcore:ListApiKeyCredentialProviders",
      "bedrock-agentcore:InvokeAgentRuntime"
    ],"Resource":"*"}
  ]
}
EOFPOL

aws iam put-role-policy \
    --role-name "$GATEWAY_ROLE_NAME" \
    --policy-name "${GATEWAY_NAME}-policy" \
    --policy-document file:///tmp/gateway-policy.json \
    --no-cli-pager
echo "  Gateway IAM policy attached."

# 3c. Create/reuse Cognito M2M client (client secret not available from CFN outputs)
GATEWAY_CLIENT_NAME="${GATEWAY_NAME}-client"
GATEWAY_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
    --user-pool-id "$USER_POOL_ID" \
    --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='${GATEWAY_CLIENT_NAME}'].ClientId | [0]" \
    --output text 2>/dev/null || echo "")

if [ -z "$GATEWAY_CLIENT_ID" ] || [ "$GATEWAY_CLIENT_ID" = "None" ]; then
    echo "  Creating gateway M2M Cognito client..."
    CLIENT_RESPONSE=$(aws cognito-idp create-user-pool-client \
        --user-pool-id "$USER_POOL_ID" \
        --client-name "$GATEWAY_CLIENT_NAME" \
        --generate-secret \
        --allowed-o-auth-flows client_credentials \
        --allowed-o-auth-scopes "gateway-api/invoke" \
        --allowed-o-auth-flows-user-pool-client \
        --region "$AWS_REGION" --no-cli-pager)
    GATEWAY_CLIENT_ID=$(echo "$CLIENT_RESPONSE" | jq -r '.UserPoolClient.ClientId')
    GATEWAY_CLIENT_SECRET=$(echo "$CLIENT_RESPONSE" | jq -r '.UserPoolClient.ClientSecret')
    echo "  Created gateway client: $GATEWAY_CLIENT_ID"
else
    echo "  Reusing gateway client: $GATEWAY_CLIENT_ID"
    GATEWAY_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$GATEWAY_CLIENT_ID" \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientSecret' --output text)
fi

GATEWAY_SCOPE="gateway-api/invoke"

# 3d. Create/update AgentCore Gateway with Cognito JWT authorizer
EXISTING_GW_ID=$(aws bedrock-agentcore-control list-gateways \
    --region "$AWS_REGION" \
    --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_GW_ID" ] && [ "$EXISTING_GW_ID" != "None" ]; then
    EXISTING_AUTH=$(aws bedrock-agentcore-control get-gateway \
        --gateway-identifier "$EXISTING_GW_ID" \
        --region "$AWS_REGION" \
        --query 'authorizerType' --output text 2>/dev/null || echo "NONE")

    if [ "$EXISTING_AUTH" = "CUSTOM_JWT" ]; then
        echo "  Reusing existing JWT gateway: $EXISTING_GW_ID"
        GATEWAY_ID="$EXISTING_GW_ID"
    else
        echo "  Existing gateway uses $EXISTING_AUTH — recreating with CUSTOM_JWT..."
        # Delete targets first
        TARGET_IDS=$(aws bedrock-agentcore-control list-gateway-targets \
            --gateway-identifier "$EXISTING_GW_ID" \
            --region "$AWS_REGION" \
            --query 'items[].targetId' --output text 2>/dev/null || echo "")
        for TID in $TARGET_IDS; do
            aws bedrock-agentcore-control delete-gateway-target \
                --gateway-identifier "$EXISTING_GW_ID" \
                --target-identifier "$TID" \
                --region "$AWS_REGION" --no-cli-pager 2>/dev/null || true
        done
        aws bedrock-agentcore-control delete-gateway \
            --gateway-identifier "$EXISTING_GW_ID" \
            --region "$AWS_REGION" --no-cli-pager 2>/dev/null || true
        echo "  Waiting for gateway deletion..."
        for i in $(seq 1 30); do
            STILL=$(aws bedrock-agentcore-control list-gateways \
                --region "$AWS_REGION" \
                --query "items[?gatewayId=='${EXISTING_GW_ID}'].gatewayId | [0]" \
                --output text 2>/dev/null || echo "None")
            [ "$STILL" = "None" ] || [ -z "$STILL" ] && break
            echo "    Still deleting... ($i/30)"
            sleep 5
        done
        EXISTING_GW_ID="None"
    fi
fi

if [ -z "$EXISTING_GW_ID" ] || [ "$EXISTING_GW_ID" = "None" ]; then
    echo "  Creating AgentCore Gateway: $GATEWAY_NAME"
    GW_RESPONSE=$(aws bedrock-agentcore-control create-gateway \
        --name "$GATEWAY_NAME" \
        --description "MCP gateway exposing the Product Catalog REST API as tool targets for the SAP supply chain agent" \
        --role-arn "$GATEWAY_ROLE_ARN" \
        --protocol-type MCP \
        --authorizer-type CUSTOM_JWT \
        --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${COGNITO_DISCOVERY}\",\"allowedClients\":[\"${GATEWAY_CLIENT_ID}\"]}}" \
        --region "$AWS_REGION" --no-cli-pager)
    GATEWAY_ID=$(echo "$GW_RESPONSE" | jq -r '.gatewayId')
    echo "  Created gateway: $GATEWAY_ID"
fi

# Wait for gateway READY
echo "  Waiting for gateway to be READY..."
while true; do
    GW_STATUS=$(aws bedrock-agentcore-control get-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'status' --output text)
    echo "    Status: $GW_STATUS"
    if [ "$GW_STATUS" = "READY" ] || [ "$GW_STATUS" = "ACTIVE" ]; then break; fi
    if [ "$GW_STATUS" = "FAILED" ]; then echo "ERROR: Gateway creation failed"; exit 1; fi
    sleep 10
done

GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
    --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" \
    --query 'gatewayUrl' --output text 2>/dev/null || echo "")

# 3e. Register Product Catalog OpenAPI target
EXISTING_TARGET_ID=$(aws bedrock-agentcore-control list-gateway-targets \
    --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" \
    --query "items[?name=='${TARGET_NAME}'].targetId | [0]" \
    --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_TARGET_ID" ] || [ "$EXISTING_TARGET_ID" = "None" ]; then
    echo "  Fetching OpenAPI spec from ${PRODUCT_CATALOG_URL}/v3/api-docs..."
    OPENAPI_SPEC=$(curl -s -H "x-api-key: ${PRODUCT_CATALOG_API_KEY}" "${PRODUCT_CATALOG_URL}/v3/api-docs")
    if [ -z "$OPENAPI_SPEC" ]; then
        echo "ERROR: Could not fetch OpenAPI spec from ${PRODUCT_CATALOG_URL}/v3/api-docs"
        exit 1
    fi

    # Fix server URL and replace unsupported */* media types
    OPENAPI_SPEC=$(echo "$OPENAPI_SPEC" | jq --arg url "${PRODUCT_CATALOG_URL}" \
        '.servers = [{"url": $url, "description": "Product Catalog API"}]')
    OPENAPI_SPEC=$(echo "$OPENAPI_SPEC" | jq '
        walk(if type == "object" and has("*/*") then
            . + {"application/json": .["*/*"]} | del(.["*/*"])
        else . end)')

    OPENAPI_SPEC_ESCAPED=$(echo "$OPENAPI_SPEC" | jq -c '.' | jq -Rs '.')

    aws bedrock-agentcore-control create-gateway-target \
        --gateway-identifier "$GATEWAY_ID" \
        --name "$TARGET_NAME" \
        --target-configuration "{\"mcp\":{\"openApiSchema\":{\"inlinePayload\":${OPENAPI_SPEC_ESCAPED}}}}" \
        --credential-provider-configurations "[{\"credentialProviderType\":\"API_KEY\",\"credentialProvider\":{\"apiKeyCredentialProvider\":{\"providerArn\":\"${CREDENTIAL_PROVIDER_ARN}\",\"credentialParameterName\":\"x-api-key\",\"credentialLocation\":\"HEADER\"}}}]" \
        --region "$AWS_REGION" --no-cli-pager
    echo "  Target registered: $TARGET_NAME"
else
    echo "  Target already exists: $EXISTING_TARGET_ID — skipping."
fi

# ===================================================================
# Step 4: Build Java application
# ===================================================================
echo ""
echo ">>> Step 4: Building Java application..."
cd "$PROJECT_ROOT"
./mvnw clean package -DskipTests -ntp
echo "Build complete."

# ===================================================================
# Step 5: Build and push Docker image (linux/arm64)
# ===================================================================
echo ""
echo ">>> Step 5: Building and pushing Docker image..."
IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker run --privileged --rm tonistiigi/binfmt --install arm64 2>/dev/null || true
docker buildx rm arm64builder 2>/dev/null || true
docker buildx create --name arm64builder --driver docker-container --bootstrap --use

docker buildx build \
    --platform linux/arm64 \
    -t "$IMAGE_URI" \
    --push \
    "$PROJECT_ROOT"

echo "Pushed: $IMAGE_URI"

# ===================================================================
# Step 6: Deploy AgentCore Runtime (two-step for OTEL)
# ===================================================================
echo ""
echo ">>> Step 6: Deploying AgentCore Runtime..."

EXISTING_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$AWS_REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
    --output text 2>/dev/null || echo "")

OTEL_REF="${EXISTING_ID}"
if [ -z "$OTEL_REF" ] || [ "$OTEL_REF" = "None" ]; then
    OTEL_REF="$RUNTIME_NAME"
fi

# Strip /mcp suffix from gateway URL for Spring AI property (url + endpoint separately)
PRODUCT_CATALOG_GATEWAY_URL="${GATEWAY_URL%/mcp}"

build_env_vars() {
    local ref="$1"
    cat > /tmp/env-vars.json <<EOFENV
{
  "AICORE_SERVICE_KEY": $(echo "${AICORE_SERVICE_KEY}" | jq -R .),
  "SAP_S4HANA_PUBLIC_CLOUD_KEY": "${SAP_S4HANA_PUBLIC_CLOUD_KEY}",
  "AGENTCORE_MEMORY_MEMORY_ID": "${AGENTCORE_MEMORY_MEMORY_ID}",
  "GATEWAY_CLIENT_ID": "${GATEWAY_CLIENT_ID}",
  "GATEWAY_CLIENT_SECRET": "${GATEWAY_CLIENT_SECRET}",
  "GATEWAY_TOKEN_ENDPOINT": "${TOKEN_ENDPOINT}",
  "GATEWAY_SCOPE": "${GATEWAY_SCOPE}",
  "PRODUCT_CATALOG_GATEWAY_URL": "${PRODUCT_CATALOG_GATEWAY_URL}",
  "AGENT_OBSERVABILITY_ENABLED": "true",
  "AGENT_NAME": "${RUNTIME_NAME}",
  "OTEL_SERVICE_NAME": "sapaiagent",
  "OTEL_RESOURCE_ATTRIBUTES": "service.name=sapaiagent,deployment.environment=production,aws.log.group.names=/aws/bedrock-agentcore/runtimes/${ref}-DEFAULT,cloud.resource_id=arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${ref}:DEFAULT",
  "OTEL_PROPAGATORS": "xray,tracecontext,baggage",
  "OTEL_TRACES_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://xray.${AWS_REGION}.amazonaws.com/v1/traces",
  "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
  "OTEL_LOGS_EXPORTER": "none",
  "OTEL_METRICS_EXPORTER": "none",
  "MANAGEMENT_TRACING_SAMPLING_PROBABILITY": "1.0"
}
EOFENV
chmod 600 /tmp/env-vars.json
}

build_env_vars "$OTEL_REF"

ARTIFACT="{\"containerConfiguration\":{\"containerUri\":\"${IMAGE_URI}\"}}"
AUTHORIZER="{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${COGNITO_DISCOVERY}\",\"allowedClients\":[\"${APP_CLIENT_ID}\"]}}"
HEADERS='{"requestHeaderAllowlist":["Authorization"]}'

if [ -z "$EXISTING_ID" ] || [ "$EXISTING_ID" = "None" ]; then
    echo "Creating new AgentCore runtime: $RUNTIME_NAME"
    RESPONSE=$(aws bedrock-agentcore-control create-agent-runtime \
        --agent-runtime-name "$RUNTIME_NAME" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --agent-runtime-artifact "$ARTIFACT" \
        --environment-variables file:///tmp/env-vars.json \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --authorizer-configuration "$AUTHORIZER" \
        --request-header-configuration "$HEADERS" \
        --region "$AWS_REGION")
    RUNTIME_ID=$(echo "$RESPONSE" | jq -r '.agentRuntimeId')

    echo "  Updating env vars with real runtime ID: $RUNTIME_ID"
    build_env_vars "$RUNTIME_ID"
    aws bedrock-agentcore-control update-agent-runtime \
        --agent-runtime-id "$RUNTIME_ID" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --agent-runtime-artifact "$ARTIFACT" \
        --environment-variables file:///tmp/env-vars.json \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --authorizer-configuration "$AUTHORIZER" \
        --request-header-configuration "$HEADERS" \
        --region "$AWS_REGION" > /dev/null
else
    echo "Updating existing runtime: $EXISTING_ID"
    aws bedrock-agentcore-control update-agent-runtime \
        --agent-runtime-id "$EXISTING_ID" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --agent-runtime-artifact "$ARTIFACT" \
        --environment-variables file:///tmp/env-vars.json \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --authorizer-configuration "$AUTHORIZER" \
        --request-header-configuration "$HEADERS" \
        --region "$AWS_REGION" > /dev/null
    RUNTIME_ID="$EXISTING_ID"
fi

# ===================================================================
# Step 7: Wait for READY
# ===================================================================
echo ""
echo ">>> Step 7: Waiting for runtime to be READY..."
while true; do
    STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
        --agent-runtime-id "$RUNTIME_ID" \
        --region "$AWS_REGION" \
        --query 'status' --output text)
    echo "  Status: $STATUS"
    if [ "$STATUS" = "READY" ]; then break; fi
    if [ "$STATUS" = "FAILED" ]; then echo "ERROR: Runtime deployment failed"; exit 1; fi
    sleep 15
done

RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${RUNTIME_ID}"
RUNTIME_ARN_ENCODED=$(echo -n "${RUNTIME_ARN}" | jq -sRr @uri)
RUNTIME_ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ARN_ENCODED}/invocations?qualifier=DEFAULT"

# ===================================================================
# Step 8: Deploy GUI to S3 + CloudFront
# ===================================================================
echo ""
echo ">>> Step 8: Deploying GUI..."
GUI_STATIC_DIR="$PROJECT_ROOT/src/main/resources/static"

if [ -d "$GUI_STATIC_DIR" ] && [ "$(ls -A "$GUI_STATIC_DIR" 2>/dev/null)" ]; then
    cat > /tmp/gui-config.json <<EOFCFG
{
  "userPoolId": "${USER_POOL_ID}",
  "clientId": "${APP_CLIENT_ID}",
  "region": "${AWS_REGION}",
  "apiEndpoint": "${RUNTIME_ENDPOINT}"
}
EOFCFG
    chmod 600 /tmp/gui-config.json

    aws s3 cp /tmp/gui-config.json "s3://${GUI_BUCKET}/config.json" \
        --content-type "application/json" --quiet

    for file in "$GUI_STATIC_DIR"/*; do
        [ -f "$file" ] || continue
        filename=$(basename "$file")
        [ "$filename" = "config.json" ] && continue
        case "$filename" in
            *.html) ct="text/html" ;;
            *.js)   ct="application/javascript" ;;
            *.css)  ct="text/css" ;;
            *.svg)  ct="image/svg+xml" ;;
            *.json) ct="application/json" ;;
            *)      ct="application/octet-stream" ;;
        esac
        aws s3 cp "$file" "s3://${GUI_BUCKET}/${filename}" \
            --content-type "$ct" --quiet
        echo "  Uploaded: $filename"
    done

    aws cloudfront create-invalidation \
        --distribution-id "$CF_DIST_ID" \
        --paths "/*" > /dev/null 2>&1
    echo "  CloudFront cache invalidated."
else
    echo "  No GUI files found — skipping."
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "================================================================="
echo " DEPLOYMENT COMPLETE"
echo "================================================================="
echo ""
echo " Runtime endpoint:  $RUNTIME_ENDPOINT"
echo " GUI URL:           https://${CF_DOMAIN}"
echo " Gateway URL:       $GATEWAY_URL"
echo " Memory ID:         $AGENTCORE_MEMORY_MEMORY_ID"
echo ""

cat > "$SCRIPT_DIR/.runtime-state" <<EOFSTATE
RUNTIME_ID=${RUNTIME_ID}
AGENTCORE_MEMORY_MEMORY_ID=${AGENTCORE_MEMORY_MEMORY_ID}
GATEWAY_ID=${GATEWAY_ID}
GATEWAY_URL=${GATEWAY_URL}
PRODUCT_CATALOG_GATEWAY_URL=${PRODUCT_CATALOG_GATEWAY_URL}
GATEWAY_CLIENT_ID=${GATEWAY_CLIENT_ID}
GATEWAY_CLIENT_SECRET=${GATEWAY_CLIENT_SECRET}
GATEWAY_TOKEN_ENDPOINT=${TOKEN_ENDPOINT}
USER_POOL_ID=${USER_POOL_ID}
CF_STACK_NAME=${CF_STACK_NAME}
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
EOFSTATE

echo "State saved to deploy/cloudformation/.runtime-state"
