#!/usr/bin/env bash
# ===================================================================
# cleanup.sh — Tear down all resources for sapaiagent-gateway
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env safely (avoids shell expansion of $, !, | etc. in JSON values)
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

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-sapaiagent-gateway}"
CF_STACK_NAME="${PROJECT_NAME}-infra"
CREDENTIAL_PROVIDER_NAME="${PROJECT_NAME}-catalog-apikey"
TARGET_NAME="${PROJECT_NAME}-catalog-target"
GATEWAY_NAME="sapaiagent-tools-gateway"

RUNTIME_ID=""
AGENTCORE_MEMORY_MEMORY_ID=""
GATEWAY_ID=""
GATEWAY_CLIENT_ID=""
USER_POOL_ID=""
if [ -f "$SCRIPT_DIR/.runtime-state" ]; then
    set -a; source "$SCRIPT_DIR/.runtime-state"; set +a
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Cleanup: $PROJECT_NAME ==="
echo "Region: $AWS_REGION  Stack: $CF_STACK_NAME"
echo ""

# 1. Delete gateway targets
if [ -n "$GATEWAY_ID" ] && [ "$GATEWAY_ID" != "None" ]; then
    echo "Deleting gateway targets for: $GATEWAY_ID"
    TARGET_IDS=$(aws bedrock-agentcore-control list-gateway-targets \
        --gateway-identifier "$GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'items[].targetId' --output text 2>/dev/null || echo "")
    for TID in $TARGET_IDS; do
        echo "  Deleting target: $TID"
        aws bedrock-agentcore-control delete-gateway-target \
            --gateway-identifier "$GATEWAY_ID" \
            --target-identifier "$TID" \
            --region "$AWS_REGION" --no-cli-pager 2>/dev/null || true
    done

    echo "Deleting AgentCore Gateway: $GATEWAY_ID"
    aws bedrock-agentcore-control delete-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --region "$AWS_REGION" --no-cli-pager 2>/dev/null || true
fi

# 2. Delete API key credential provider
echo "Deleting credential provider: $CREDENTIAL_PROVIDER_NAME"
aws bedrock-agentcore-control delete-api-key-credential-provider \
    --name "$CREDENTIAL_PROVIDER_NAME" \
    --region "$AWS_REGION" 2>/dev/null || true

# 3. Delete Cognito M2M client
if [ -n "$GATEWAY_CLIENT_ID" ] && [ "$GATEWAY_CLIENT_ID" != "None" ] && \
   [ -n "$USER_POOL_ID" ] && [ "$USER_POOL_ID" != "None" ]; then
    echo "Deleting gateway Cognito client: $GATEWAY_CLIENT_ID"
    aws cognito-idp delete-user-pool-client \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$GATEWAY_CLIENT_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
fi

# 4. Delete AgentCore runtime and its CloudWatch log group
if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
    echo "Deleting AgentCore runtime: $RUNTIME_ID"
    aws bedrock-agentcore-control delete-agent-runtime \
        --agent-runtime-id "$RUNTIME_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
    LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
    echo "Deleting CloudWatch log group: $LOG_GROUP"
    aws logs delete-log-group \
        --log-group-name "$LOG_GROUP" \
        --region "$AWS_REGION" 2>/dev/null || true
fi

# 5. Delete AgentCore Memory
# Fallback: scan by ID prefix if .runtime-state didn't have the ID
if [ -z "$AGENTCORE_MEMORY_MEMORY_ID" ] || [ "$AGENTCORE_MEMORY_MEMORY_ID" = "None" ]; then
    MEMORY_NAME="${PROJECT_NAME//-/_}"
    AGENTCORE_MEMORY_MEMORY_ID=$(aws bedrock-agentcore-control list-memories \
        --region "$AWS_REGION" \
        --query "memories[].id" \
        --output text 2>/dev/null | tr '\t' '\n' | grep "^${MEMORY_NAME}-" | head -1 || echo "")
fi
if [ -n "$AGENTCORE_MEMORY_MEMORY_ID" ] && [ "$AGENTCORE_MEMORY_MEMORY_ID" != "None" ]; then
    echo "Deleting AgentCore memory: $AGENTCORE_MEMORY_MEMORY_ID"
    aws bedrock-agentcore-control delete-memory \
        --memory-id "$AGENTCORE_MEMORY_MEMORY_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
fi

# 6. Empty S3 GUI bucket
GUI_BUCKET="${PROJECT_NAME}-gui-${ACCOUNT_ID}"
echo "Emptying S3 bucket: $GUI_BUCKET"
aws s3 rm "s3://${GUI_BUCKET}" --recursive 2>/dev/null || true

# 7. Force-delete ECR repository
ECR_REPO="${PROJECT_NAME}-ecr"
echo "Force-deleting ECR repository: $ECR_REPO"
aws ecr delete-repository \
    --repository-name "$ECR_REPO" \
    --force \
    --region "$AWS_REGION" 2>/dev/null || true

# 8. Disable CloudFront distribution before stack deletion
#    (OAC cannot be deleted while associated with an enabled distribution)
CF_DIST_ID=$(aws cloudformation describe-stacks \
    --stack-name "$CF_STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
    echo "Disabling CloudFront distribution: $CF_DIST_ID"
    ETAG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query 'ETag' --output text 2>/dev/null || echo "")
    if [ -n "$ETAG" ]; then
        aws cloudfront get-distribution-config --id "$CF_DIST_ID" \
            --query 'DistributionConfig' > /tmp/cf-dist-config.json 2>/dev/null
        jq '.Enabled = false' /tmp/cf-dist-config.json > /tmp/cf-dist-config-disabled.json
        aws cloudfront update-distribution \
            --id "$CF_DIST_ID" \
            --distribution-config file:///tmp/cf-dist-config-disabled.json \
            --if-match "$ETAG" > /dev/null 2>/dev/null || true
        echo "  Waiting for distribution to be disabled (this takes a few minutes)..."
        aws cloudfront wait distribution-deployed --id "$CF_DIST_ID" 2>/dev/null || true
        echo "  Distribution disabled."
    fi
fi

# 9. Delete CloudFormation stack
#    (removes: IAM role, Cognito user pool, S3 bucket, CloudFront distribution, OAC)
echo "Deleting CloudFormation stack: $CF_STACK_NAME"
aws cloudformation delete-stack \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"

rm -f "$SCRIPT_DIR/.runtime-state"

echo ""
echo "=== Cleanup complete ==="
