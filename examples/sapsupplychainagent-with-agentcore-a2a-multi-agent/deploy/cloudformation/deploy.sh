#!/usr/bin/env bash
# ===================================================================
# deploy.sh — Deploy all 5 A2A agents to AWS AgentCore
#
# Usage:
#   cp deploy/cloudformation/.env.example deploy/cloudformation/.env
#   # Edit .env with your values
#   ./deploy/cloudformation/deploy.sh
# ===================================================================
set -euo pipefail

cleanup_temp_files() { rm -f /tmp/gui-config.json; }
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
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
PROJECT_NAME="${PROJECT_NAME:-sap-a2a-multi-agent}"
CF_STACK_NAME="${PROJECT_NAME}-infra"
IMAGE_TAG="${IMAGE_TAG:-latest}"

AGENTS=(sap-query-agent sap-execute-format-agent date-weather-agent mcp-tools-agent orchestrator-agent)

echo "================================================================="
echo " SAP A2A Multi-Agent Deploy"
echo " Region:     $AWS_REGION"
echo " Account:    $AWS_ACCOUNT_ID"
echo " Project:    $PROJECT_NAME"
echo "================================================================="

# ===================================================================
# Step 1: Deploy CloudFormation (ECR repos, IAM, Cognito, S3, CloudFront)
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

EXECUTION_ROLE_ARN=$(read_output AgentCoreExecutionRoleArn)
USER_POOL_ID=$(read_output CognitoUserPoolId)
APP_CLIENT_ID=$(read_output CognitoAppClientId)
COGNITO_DISCOVERY=$(read_output CognitoDiscoveryUrl)
GUI_BUCKET=$(read_output GuiBucketName)
CF_DIST_ID=$(read_output GuiCloudFrontDistributionId)
CF_DOMAIN=$(read_output GuiCloudFrontDomainName)

echo "Execution role:    $EXECUTION_ROLE_ARN"
echo "Cognito pool:      $USER_POOL_ID"
echo "Cognito client:    $APP_CLIENT_ID"

# ===================================================================
# Step 2: Build all Java modules
# ===================================================================
echo ""
echo ">>> Step 2: Building all Java modules..."
cd "$PROJECT_ROOT"
./mvnw clean package -DskipTests -ntp
echo "Build complete."

# ===================================================================
# Step 3: Login to ECR
# ===================================================================
echo ""
echo ">>> Step 3: Logging in to ECR..."
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ===================================================================
# Step 4: Build and push Docker images
# ===================================================================
echo ""
echo ">>> Step 4: Building and pushing Docker images..."

# Parallel arrays to store agent->URI mappings (bash 3.x compatible)
AGENT_URI_KEYS=()
AGENT_URI_VALS=()
# Helper: set a value in a parallel-array map
_map_set() {
    local map_prefix="$1" key="$2" val="$3"
    eval "${map_prefix}_KEYS+=(\"\$key\")"
    eval "${map_prefix}_VALS+=(\"\$val\")"
}
# Helper: get a value from a parallel-array map (prints to stdout)
_map_get() {
    local map_prefix="$1" key="$2"
    local keys_var="${map_prefix}_KEYS[@]"
    local vals_var="${map_prefix}_VALS[@]"
    local keys=("${!keys_var}")
    local vals=("${!vals_var}")
    for i in "${!keys[@]}"; do
        if [ "${keys[$i]}" = "$key" ]; then
            echo "${vals[$i]}"
            return
        fi
    done
    echo ""
}

# Single ECR repo — agents distinguished by tag: {agent-name}-{IMAGE_TAG}
ECR_REPO_URI="${ECR_REGISTRY}/${PROJECT_NAME}"

for AGENT in "${AGENTS[@]}"; do
    IMAGE_URI="${ECR_REPO_URI}:${AGENT}-${IMAGE_TAG}"
    _map_set AGENT_URI "$AGENT" "$IMAGE_URI"

    echo ""
    echo "Building image for $AGENT -> $IMAGE_URI"
    cd "$PROJECT_ROOT"
    docker build \
        --platform linux/arm64 \
        -f "$AGENT/Dockerfile" \
        -t "$IMAGE_URI" \
        .

    echo "Pushing $AGENT..."
    docker push --quiet "$IMAGE_URI"
    echo "Pushed: $IMAGE_URI"
done

# ===================================================================
# Step 5: Deploy worker agents (in parallel)
# ===================================================================
echo ""
echo ">>> Step 5: Creating/updating AgentCore runtimes for worker agents..."

WORKER_AGENTS=(sap-query-agent sap-execute-format-agent date-weather-agent mcp-tools-agent)
AGENT_EP_KEYS=()
AGENT_EP_VALS=()

# Wait until an AgentCore runtime is no longer CREATING before updating it.
# Usage: wait_for_runtime_ready <runtime-id>
wait_for_runtime_ready() {
    local runtime_id="$1"
    local max_attempts=30  # 30 * 10s = 5 minutes max
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
            --agent-runtime-id "$runtime_id" \
            --region "$AWS_REGION" \
            --query 'agentRuntime.status' --output text 2>/dev/null || echo "UNKNOWN")
        if [ "$STATUS" != "CREATING" ] && [ "$STATUS" != "UPDATING" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  Waiting for runtime $runtime_id to be ready (status: $STATUS, attempt $attempt/$max_attempts)..."
        sleep 10
    done
    echo "WARNING: Runtime $runtime_id did not become ready within timeout — proceeding anyway"
}

deploy_worker() {
    local AGENT="$1"
    local IMAGE_URI="$2"

    RUNTIME_NAME="${PROJECT_NAME//-/_}_${AGENT//-/_}"

    echo "Deploying worker: $RUNTIME_NAME"

    # Check if runtime already exists (for OTEL resource attributes)
    EXISTING=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId" \
        --output text 2>/dev/null || echo "")

    # Use real runtime ID for OTEL if updating, name as placeholder if creating
    local OTEL_REF="${EXISTING}"
    if [ -z "$OTEL_REF" ] || [ "$OTEL_REF" = "None" ]; then
        OTEL_REF="$RUNTIME_NAME"
    fi

    # Write env vars to a unique temp file (JSON supports AICORE_SERVICE_KEY blob)
    local ENVFILE
    ENVFILE=$(mktemp /tmp/env-vars-XXXXXX)

    # Base OTEL env vars for AgentCore observability
    local OTEL_SVC_NAME="${AGENT}"
    local OTEL_RES_ATTRS="service.name=${OTEL_SVC_NAME},deployment.environment=production,aws.log.group.names=/aws/bedrock-agentcore/runtimes/${OTEL_REF}-DEFAULT,cloud.resource_id=arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${OTEL_REF}:DEFAULT"

    if [ "$AGENT" = "mcp-tools-agent" ] && [ -n "${PRODUCTCATALOG_GATEWAY_URL:-}" ]; then
        cat > "$ENVFILE" <<EOFJSON
{
  "SERVER_PORT": "9000",
  "AICORE_SERVICE_KEY": $(echo "${AICORE_SERVICE_KEY}" | jq -R .),
  "SAP_S4HANA_PUBLIC_CLOUD_KEY": "${SAP_S4HANA_PUBLIC_CLOUD_KEY:-}",
  "SPRING_AI_MCP_CLIENT_STREAMABLE_HTTP_CONNECTIONS_PRODUCTCATALOG_URL": "${PRODUCTCATALOG_GATEWAY_URL}",
  "SPRING_AI_MCP_CLIENT_STREAMABLE_HTTP_CONNECTIONS_PRODUCTCATALOG_ENDPOINT": "/mcp",
  "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_GATEWAY_CLIENT_ID": "${PRODUCTCATALOG_GATEWAY_CLIENT_ID:-}",
  "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_GATEWAY_CLIENT_SECRET": "${PRODUCTCATALOG_GATEWAY_CLIENT_SECRET:-}",
  "SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_GATEWAY_SCOPE": "gateway-api/invoke",
  "SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_GATEWAY_TOKEN_URI": "${PRODUCTCATALOG_GATEWAY_TOKEN_ENDPOINT:-}",
  "AGENT_OBSERVABILITY_ENABLED": "true",
  "OTEL_SERVICE_NAME": "${OTEL_SVC_NAME}",
  "OTEL_RESOURCE_ATTRIBUTES": "${OTEL_RES_ATTRS}",
  "OTEL_PROPAGATORS": "xray,tracecontext,baggage",
  "OTEL_TRACES_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://xray.${AWS_REGION}.amazonaws.com/v1/traces",
  "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT": "5000",
  "OTEL_BSP_SCHEDULE_DELAY": "5000",
  "OTEL_BSP_EXPORT_TIMEOUT": "5000",
  "OTEL_LOGS_EXPORTER": "none",
  "OTEL_METRICS_EXPORTER": "none"
}
EOFJSON
    else
        cat > "$ENVFILE" <<EOFJSON
{
  "SERVER_PORT": "9000",
  "AICORE_SERVICE_KEY": $(echo "${AICORE_SERVICE_KEY}" | jq -R .),
  "SAP_S4HANA_PUBLIC_CLOUD_KEY": "${SAP_S4HANA_PUBLIC_CLOUD_KEY:-}",
  "AGENT_OBSERVABILITY_ENABLED": "true",
  "OTEL_SERVICE_NAME": "${OTEL_SVC_NAME}",
  "OTEL_RESOURCE_ATTRIBUTES": "${OTEL_RES_ATTRS}",
  "OTEL_PROPAGATORS": "xray,tracecontext,baggage",
  "OTEL_TRACES_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://xray.${AWS_REGION}.amazonaws.com/v1/traces",
  "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT": "5000",
  "OTEL_BSP_SCHEDULE_DELAY": "5000",
  "OTEL_BSP_EXPORT_TIMEOUT": "5000",
  "OTEL_LOGS_EXPORTER": "none",
  "OTEL_METRICS_EXPORTER": "none"
}
EOFJSON
    fi

    if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
        echo "Updating existing runtime $RUNTIME_NAME ($EXISTING)..."
        aws bedrock-agentcore-control update-agent-runtime \
            --agent-runtime-id "$EXISTING" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${IMAGE_URI}\"}}" \
            --network-configuration networkMode=PUBLIC \
            --protocol-configuration serverProtocol=A2A \
            --environment-variables "file://${ENVFILE}" \
            --role-arn "$EXECUTION_ROLE_ARN" \
            --region "$AWS_REGION" > /dev/null
        RUNTIME_ID="$EXISTING"
    else
        echo "Creating new runtime $RUNTIME_NAME..."
        RESPONSE=$(aws bedrock-agentcore-control create-agent-runtime \
            --agent-runtime-name "$RUNTIME_NAME" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${IMAGE_URI}\"}}" \
            --network-configuration networkMode=PUBLIC \
            --protocol-configuration serverProtocol=A2A \
            --environment-variables "file://${ENVFILE}" \
            --role-arn "$EXECUTION_ROLE_ARN" \
            --region "$AWS_REGION")
        RUNTIME_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agentRuntimeId',''))")

        # Fix OTEL_RESOURCE_ATTRIBUTES with real runtime ID
        echo "  Updating OTEL config with real runtime ID: $RUNTIME_ID"
        wait_for_runtime_ready "$RUNTIME_ID"
        OTEL_RES_ATTRS="service.name=${OTEL_SVC_NAME},deployment.environment=production,aws.log.group.names=/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT,cloud.resource_id=arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${RUNTIME_ID}:DEFAULT"
        # Rewrite env file with real ID
        local ENVFILE2
        ENVFILE2=$(mktemp /tmp/env-vars-fix-XXXXXX)
        python3 -c "
import json, sys
with open('${ENVFILE}') as f: d = json.load(f)
d['OTEL_RESOURCE_ATTRIBUTES'] = '${OTEL_RES_ATTRS}'
json.dump(d, sys.stdout)
" > "$ENVFILE2"
        aws bedrock-agentcore-control update-agent-runtime \
            --agent-runtime-id "$RUNTIME_ID" \
            --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${IMAGE_URI}\"}}" \
            --network-configuration networkMode=PUBLIC \
            --protocol-configuration serverProtocol=A2A \
            --environment-variables "file://${ENVFILE2}" \
            --role-arn "$EXECUTION_ROLE_ARN" \
            --region "$AWS_REGION" > /dev/null
        rm -f "$ENVFILE2"
    fi

    rm -f "$ENVFILE"
    echo "Runtime $RUNTIME_NAME deployed: $RUNTIME_ID"
    echo "$AGENT:$RUNTIME_ID"
}

# Deploy workers in parallel
WORKER_PIDS=()
WORKER_OUTPUT_FILES=()

for AGENT in "${WORKER_AGENTS[@]}"; do
    OUTFILE=$(mktemp)
    WORKER_OUTPUT_FILES+=("$OUTFILE")
    deploy_worker "$AGENT" "$(_map_get AGENT_URI "$AGENT")" > "$OUTFILE" 2>&1 &
    WORKER_PIDS+=($!)
done

# Wait for all workers to complete
WORKER_FAILED=0
for i in "${!WORKER_PIDS[@]}"; do
    if ! wait "${WORKER_PIDS[$i]}"; then
        WORKER_FAILED=1
    fi
    cat "${WORKER_OUTPUT_FILES[$i]}"
    rm -f "${WORKER_OUTPUT_FILES[$i]}"
done

if [ "$WORKER_FAILED" -ne 0 ]; then
    echo "ERROR: One or more worker deployments failed. See output above."
    exit 1
fi

# Collect worker endpoints
echo ""
echo ">>> Collecting worker agent endpoints..."
for AGENT in "${WORKER_AGENTS[@]}"; do
    RUNTIME_NAME="${PROJECT_NAME//-/_}_${AGENT//-/_}"
    RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId" \
        --output text 2>/dev/null || echo "")

    if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
        AGENT_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${RUNTIME_ID}"
        AGENT_ARN_ENCODED=$(echo -n "${AGENT_ARN}" | jq -sRr @uri)
        ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${AGENT_ARN_ENCODED}/invocations?qualifier=DEFAULT"
        _map_set AGENT_EP "$AGENT" "$ENDPOINT"
        echo "  $AGENT: $ENDPOINT"
    fi
done

# ===================================================================
# Step 6: Create/reuse AgentCore Memory for orchestrator
# ===================================================================
echo ""
echo ">>> Step 6: Setting up AgentCore Memory for orchestrator..."

MEMORY_NAME="${PROJECT_NAME//-/_}_orchestrator_memory"
AGENTCORE_MEMORY_MEMORY_ID=""

EXISTING_MEMORY_ID=$(aws bedrock-agentcore-control list-memories \
    --region "$AWS_REGION" \
    --query "memories[].id" \
    --output text 2>/dev/null | tr '\t' '\n' | grep "^${MEMORY_NAME}-" | head -1 || echo "")

if [ -n "$EXISTING_MEMORY_ID" ] && [ "$EXISTING_MEMORY_ID" != "None" ]; then
    echo "Reusing existing memory resource: $EXISTING_MEMORY_ID"
    AGENTCORE_MEMORY_MEMORY_ID="$EXISTING_MEMORY_ID"
else
    echo "Creating memory resource: $MEMORY_NAME"
    STRATEGIES=$(mktemp)
    cat > "$STRATEGIES" <<'EOF'
[{"semanticMemoryStrategy":{"name":"facts","namespaces":["/strategies/{memoryStrategyId}/actors/{actorId}/"]}}]
EOF
    MEMORY_RESPONSE=$(aws bedrock-agentcore-control create-memory \
        --name "$MEMORY_NAME" \
        --description "SAP A2A Multi-Agent Orchestrator — conversation memory" \
        --event-expiry-duration 90 \
        --memory-strategies "file://${STRATEGIES}" \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    rm -f "$STRATEGIES"

    if [ -n "$MEMORY_RESPONSE" ]; then
        AGENTCORE_MEMORY_MEMORY_ID=$(echo "$MEMORY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memory',{}).get('id',''))" 2>/dev/null || echo "")
        echo "Memory created: $AGENTCORE_MEMORY_MEMORY_ID"

        if [ -n "$AGENTCORE_MEMORY_MEMORY_ID" ]; then
            echo "Waiting for memory to become ACTIVE..."
            for i in $(seq 1 12); do
                STATUS=$(aws bedrock-agentcore-control get-memory \
                    --memory-id "$AGENTCORE_MEMORY_MEMORY_ID" \
                    --region "$AWS_REGION" \
                    --query 'memory.status' --output text 2>/dev/null || echo "UNKNOWN")
                echo "  Status: $STATUS"
                if [ "$STATUS" = "ACTIVE" ]; then break; fi
                if [ "$STATUS" = "FAILED" ]; then
                    echo "WARNING: Memory creation failed — deploying without memory"
                    AGENTCORE_MEMORY_MEMORY_ID=""
                    break
                fi
                sleep 10
            done
        fi
    else
        echo "WARNING: Memory creation failed — deploying without memory"
    fi
fi

cat > "$SCRIPT_DIR/.memory-config" <<EOF
AGENTCORE_MEMORY_MEMORY_ID=${AGENTCORE_MEMORY_MEMORY_ID}
MEMORY_NAME=${MEMORY_NAME}
AWS_REGION=${AWS_REGION}
EOF
echo "Memory config saved to deploy/cloudformation/.memory-config"

# ===================================================================
# Step 7: Deploy orchestrator with worker URLs + memory ID
# ===================================================================
echo ""
echo ">>> Step 7: Deploying orchestrator agent..."

ORCH_RUNTIME_NAME="${PROJECT_NAME//-/_}_orchestrator_agent"

# Determine OTEL reference (real ID if updating, name if creating)
EXISTING_ORCH=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$AWS_REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${ORCH_RUNTIME_NAME}'].agentRuntimeId" \
    --output text 2>/dev/null || echo "")

ORCH_OTEL_REF="${EXISTING_ORCH}"
if [ -z "$ORCH_OTEL_REF" ] || [ "$ORCH_OTEL_REF" = "None" ]; then
    ORCH_OTEL_REF="$ORCH_RUNTIME_NAME"
fi

ORCH_OTEL_SVC="orchestrator-agent"
ORCH_OTEL_RES="service.name=${ORCH_OTEL_SVC},deployment.environment=production,aws.log.group.names=/aws/bedrock-agentcore/runtimes/${ORCH_OTEL_REF}-DEFAULT,cloud.resource_id=arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${ORCH_OTEL_REF}:DEFAULT"

# Write orchestrator env vars to JSON file (supports AICORE_SERVICE_KEY blob)
ORCH_ENVFILE=$(mktemp /tmp/env-vars-orch-XXXXXX)
cat > "$ORCH_ENVFILE" <<EOFJSON
{
  "SERVER_PORT": "8080",
  "AICORE_SERVICE_KEY": $(echo "${AICORE_SERVICE_KEY}" | jq -R .),
  "A2A_AGENTS_SAP-QUERY-AGENT_URL": "$(_map_get AGENT_EP sap-query-agent)",
  "A2A_AGENTS_SAP-EXECUTE-FORMAT-AGENT_URL": "$(_map_get AGENT_EP sap-execute-format-agent)",
  "A2A_AGENTS_DATE-WEATHER-AGENT_URL": "$(_map_get AGENT_EP date-weather-agent)",
  "A2A_AGENTS_MCP-TOOLS-AGENT_URL": "$(_map_get AGENT_EP mcp-tools-agent)",
  "AGENTCORE_MEMORY_MEMORY_ID": "${AGENTCORE_MEMORY_MEMORY_ID:-}",
  "AGENT_OBSERVABILITY_ENABLED": "true",
  "OTEL_SERVICE_NAME": "${ORCH_OTEL_SVC}",
  "OTEL_RESOURCE_ATTRIBUTES": "${ORCH_OTEL_RES}",
  "OTEL_PROPAGATORS": "xray,tracecontext,baggage",
  "OTEL_TRACES_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://xray.${AWS_REGION}.amazonaws.com/v1/traces",
  "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT": "5000",
  "OTEL_BSP_SCHEDULE_DELAY": "5000",
  "OTEL_BSP_EXPORT_TIMEOUT": "5000",
  "OTEL_LOGS_EXPORTER": "none",
  "OTEL_METRICS_EXPORTER": "none"
}
EOFJSON

COGNITO_AUTHORIZER_CONFIG="{\"customJWTAuthorizer\":{\"discoveryUrl\":\"${COGNITO_DISCOVERY}\",\"allowedClients\":[\"${APP_CLIENT_ID}\"]}}"
REQUEST_HEADER_CONFIG='{"requestHeaderAllowlist":["Authorization"]}'

if [ -n "$EXISTING_ORCH" ] && [ "$EXISTING_ORCH" != "None" ]; then
    aws bedrock-agentcore-control update-agent-runtime \
        --agent-runtime-id "$EXISTING_ORCH" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$(_map_get AGENT_URI orchestrator-agent)\"}}" \
        --network-configuration networkMode=PUBLIC \
        --environment-variables "file://${ORCH_ENVFILE}" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --authorizer-configuration "$COGNITO_AUTHORIZER_CONFIG" \
        --request-header-configuration "$REQUEST_HEADER_CONFIG" \
        --region "$AWS_REGION" > /dev/null
    ORCH_ID="$EXISTING_ORCH"
else
    ORCH_RESPONSE=$(aws bedrock-agentcore-control create-agent-runtime \
        --agent-runtime-name "$ORCH_RUNTIME_NAME" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$(_map_get AGENT_URI orchestrator-agent)\"}}" \
        --network-configuration networkMode=PUBLIC \
        --environment-variables "file://${ORCH_ENVFILE}" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --authorizer-configuration "$COGNITO_AUTHORIZER_CONFIG" \
        --request-header-configuration "$REQUEST_HEADER_CONFIG" \
        --region "$AWS_REGION")
    ORCH_ID=$(echo "$ORCH_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agentRuntimeId',''))")

    # Fix OTEL_RESOURCE_ATTRIBUTES with real runtime ID
    echo "  Updating OTEL config with real orchestrator runtime ID: $ORCH_ID"
    wait_for_runtime_ready "$ORCH_ID"
    ORCH_OTEL_RES="service.name=${ORCH_OTEL_SVC},deployment.environment=production,aws.log.group.names=/aws/bedrock-agentcore/runtimes/${ORCH_ID}-DEFAULT,cloud.resource_id=arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${ORCH_ID}:DEFAULT"
    ORCH_ENVFILE2=$(mktemp /tmp/env-vars-orch-fix-XXXXXX)
    python3 -c "
import json, sys
with open('${ORCH_ENVFILE}') as f: d = json.load(f)
d['OTEL_RESOURCE_ATTRIBUTES'] = '${ORCH_OTEL_RES}'
json.dump(d, sys.stdout)
" > "$ORCH_ENVFILE2"
    aws bedrock-agentcore-control update-agent-runtime \
        --agent-runtime-id "$ORCH_ID" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$(_map_get AGENT_URI orchestrator-agent)\"}}" \
        --network-configuration networkMode=PUBLIC \
        --environment-variables "file://${ORCH_ENVFILE2}" \
        --role-arn "$EXECUTION_ROLE_ARN" \
        --authorizer-configuration "$COGNITO_AUTHORIZER_CONFIG" \
        --request-header-configuration "$REQUEST_HEADER_CONFIG" \
        --region "$AWS_REGION" > /dev/null
    rm -f "$ORCH_ENVFILE2"
fi
rm -f "$ORCH_ENVFILE"

ORCH_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${ORCH_ID}"
ORCH_ARN_ENCODED=$(echo -n "${ORCH_ARN}" | jq -sRr @uri)
ORCH_ENDPOINT="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${ORCH_ARN_ENCODED}/invocations?qualifier=DEFAULT"

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "================================================================="
echo " DEPLOYMENT COMPLETE"
echo "================================================================="
echo ""
echo " Orchestrator endpoint: $ORCH_ENDPOINT"
echo ""
echo " Worker endpoints:"
for AGENT in "${WORKER_AGENTS[@]}"; do
    echo "   $AGENT: $(_map_get AGENT_EP "$AGENT")"
done
echo ""

cat > "$SCRIPT_DIR/.runtime-config" <<EOF
ORCH_RUNTIME_ID=${ORCH_ID}
CF_STACK_NAME=${CF_STACK_NAME}
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
EOF
echo "Runtime config saved to deploy/cloudformation/.runtime-config"

# ===================================================================
# Step 8: Deploy GUI to CloudFront (optional)
# ===================================================================
GUI_STATIC_DIR="$PROJECT_ROOT/orchestrator-agent/src/main/resources/static"

if [ -d "$GUI_STATIC_DIR" ] && [ "$(ls -A "$GUI_STATIC_DIR" 2>/dev/null)" ]; then
    echo ""
    echo ">>> Step 8: Deploying GUI to CloudFront..."

    if [ -n "$GUI_BUCKET" ] && [ "$GUI_BUCKET" != "None" ] && [ -n "$CF_DIST_ID" ]; then
        cat > /tmp/gui-config.json <<EOFGUICFG
{
  "apiEndpoint": "${ORCH_ENDPOINT}",
  "region": "${AWS_REGION}",
  "userPoolId": "${USER_POOL_ID}",
  "clientId": "${APP_CLIENT_ID}"
}
EOFGUICFG
        chmod 600 /tmp/gui-config.json
        aws s3 cp /tmp/gui-config.json "s3://${GUI_BUCKET}/config.json" \
            --content-type "application/json" --quiet
        echo "  Uploaded: config.json"

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

        cat > "$SCRIPT_DIR/.cloudfront-config" <<EOFCF
GUI_BUCKET=${GUI_BUCKET}
CF_DIST_ID=${CF_DIST_ID}
CF_DOMAIN=${CF_DOMAIN}
EOFCF
        echo ""
        echo " GUI URL: https://${CF_DOMAIN}"
        echo " CloudFront config saved to deploy/cloudformation/.cloudfront-config"
    else
        echo "WARNING: CloudFront outputs not found — skipping GUI upload"
    fi
else
    echo "No GUI files found in orchestrator-agent/src/main/resources/static — skipping Step 8"
fi
