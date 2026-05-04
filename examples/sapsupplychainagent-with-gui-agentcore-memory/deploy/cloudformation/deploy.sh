#!/usr/bin/env bash
# ===================================================================
# deploy.sh — Deploy SAP AI Agent (with memory) to AWS AgentCore
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
PROJECT_NAME="${PROJECT_NAME:-sapaiagent-memory}"
CF_STACK_NAME="${PROJECT_NAME}-infra"
IMAGE_TAG="${IMAGE_TAG:-latest}"
RUNTIME_NAME="${PROJECT_NAME//-/_}_runtime"
MEMORY_NAME="${PROJECT_NAME//-/_}"

: "${AICORE_SERVICE_KEY:?Set AICORE_SERVICE_KEY in deploy/cloudformation/.env}"
: "${SAP_S4HANA_PUBLIC_CLOUD_KEY:?Set SAP_S4HANA_PUBLIC_CLOUD_KEY in deploy/cloudformation/.env}"

echo "================================================================="
echo " SAP AI Agent — AgentCore Memory"
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
USER_POOL_ID=$(read_output UserPoolId)
APP_CLIENT_ID=$(read_output AppClientId)
COGNITO_DISCOVERY=$(read_output CognitoDiscoveryUrl)
GUI_BUCKET=$(read_output GuiBucketName)
CF_DIST_ID=$(read_output CloudFrontDistributionId)
CF_DOMAIN=$(read_output CloudFrontDomain)

echo "ECR:            $ECR_URI"
echo "Role:           $EXECUTION_ROLE_ARN"
echo "Cognito pool:   $USER_POOL_ID / client: $APP_CLIENT_ID"

# ===================================================================
# Step 2: Create/reuse AgentCore Memory
# (No CFN resource type — managed via CLI)
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
        --description "SAP AI Agent — conversation memory (STM facts + user preferences)" \
        --event-expiry-duration 90 \
        --memory-strategies "file://${STRATEGIES}" \
        --region "$AWS_REGION")
    rm -f "$STRATEGIES"
    AGENTCORE_MEMORY_MEMORY_ID=$(echo "$MEMORY_RESPONSE" | jq -r '.memory.id')
    echo "  Memory created: $AGENTCORE_MEMORY_MEMORY_ID"

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
# Step 3: Build Java application
# ===================================================================
echo ""
echo ">>> Step 3: Building Java application..."
cd "$PROJECT_ROOT"
./mvnw clean package -DskipTests -ntp
echo "Build complete."

# ===================================================================
# Step 4: Build and push Docker image (linux/arm64)
# ===================================================================
echo ""
echo ">>> Step 4: Building and pushing Docker image..."
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
# Step 5: Deploy AgentCore Runtime (two-step for OTEL)
# ===================================================================
echo ""
echo ">>> Step 5: Deploying AgentCore Runtime..."

EXISTING_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$AWS_REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
    --output text 2>/dev/null || echo "")

OTEL_REF="${EXISTING_ID}"
if [ -z "$OTEL_REF" ] || [ "$OTEL_REF" = "None" ]; then
    OTEL_REF="$RUNTIME_NAME"
fi

build_env_vars() {
    local ref="$1"
    cat > /tmp/env-vars.json <<EOFENV
{
  "AICORE_SERVICE_KEY": $(echo "${AICORE_SERVICE_KEY}" | jq -R .),
  "SAP_S4HANA_PUBLIC_CLOUD_KEY": "${SAP_S4HANA_PUBLIC_CLOUD_KEY}",
  "AGENTCORE_MEMORY_MEMORY_ID": "${AGENTCORE_MEMORY_MEMORY_ID}",
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
# Step 6: Wait for READY
# ===================================================================
echo ""
echo ">>> Step 6: Waiting for runtime to be READY..."
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
# Step 7: Deploy GUI to S3 + CloudFront
# ===================================================================
echo ""
echo ">>> Step 7: Deploying GUI..."
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
echo " Memory ID:         $AGENTCORE_MEMORY_MEMORY_ID"
echo ""

cat > "$SCRIPT_DIR/.runtime-state" <<EOFSTATE
RUNTIME_ID=${RUNTIME_ID}
AGENTCORE_MEMORY_MEMORY_ID=${AGENTCORE_MEMORY_MEMORY_ID}
CF_STACK_NAME=${CF_STACK_NAME}
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
EOFSTATE

echo "State saved to deploy/cloudformation/.runtime-state"
