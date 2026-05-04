#!/usr/bin/env bash
# ===================================================================
# cleanup.sh — Tear down all resources for sap-a2a-multi-agent
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
PROJECT_NAME="${PROJECT_NAME:-sap-a2a-multi-agent}"
CF_STACK_NAME="${PROJECT_NAME}-infra"

ORCH_RUNTIME_ID=""
if [ -f "$SCRIPT_DIR/.runtime-config" ]; then
    set -a; source "$SCRIPT_DIR/.runtime-config"; set +a
fi

AGENTCORE_MEMORY_MEMORY_ID=""
if [ -f "$SCRIPT_DIR/.memory-config" ]; then
    set -a; source "$SCRIPT_DIR/.memory-config"; set +a
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Cleanup: $PROJECT_NAME ==="
echo "Region: $AWS_REGION  Stack: $CF_STACK_NAME"
echo ""

# 1. Delete all AgentCore runtimes (workers + orchestrator) and their CloudWatch log groups
ALL_AGENTS=(sap-query-agent sap-execute-format-agent date-weather-agent mcp-tools-agent orchestrator-agent)
for AGENT in "${ALL_AGENTS[@]}"; do
    RUNTIME_NAME="${PROJECT_NAME//-/_}_${AGENT//-/_}"
    RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
        --output text 2>/dev/null || echo "")
    if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
        echo "Deleting runtime: $RUNTIME_NAME ($RUNTIME_ID)"
        aws bedrock-agentcore-control delete-agent-runtime \
            --agent-runtime-id "$RUNTIME_ID" \
            --region "$AWS_REGION" 2>/dev/null || true
        LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
        echo "Deleting CloudWatch log group: $LOG_GROUP"
        aws logs delete-log-group \
            --log-group-name "$LOG_GROUP" \
            --region "$AWS_REGION" 2>/dev/null || true
    fi
done

# 2. Delete AgentCore Memory
if [ -n "$AGENTCORE_MEMORY_MEMORY_ID" ] && [ "$AGENTCORE_MEMORY_MEMORY_ID" != "None" ]; then
    echo "Deleting AgentCore memory: $AGENTCORE_MEMORY_MEMORY_ID"
    aws bedrock-agentcore-control delete-memory \
        --memory-id "$AGENTCORE_MEMORY_MEMORY_ID" \
        --region "$AWS_REGION" 2>/dev/null || true
fi

# 3. Empty GUI S3 bucket — delete all versions and delete markers so CloudFormation
#    can remove the bucket. aws s3 rm --recursive only removes current-version objects;
#    versioned buckets also accumulate delete markers that must be purged separately.
#
#    Bucket name is read from .cloudfront-config (written by deploy.sh) so we use the
#    exact name CloudFormation chose rather than guessing it.
GUI_BUCKET=""
if [ -f "$SCRIPT_DIR/.cloudfront-config" ]; then
    GUI_BUCKET=$(grep '^GUI_BUCKET=' "$SCRIPT_DIR/.cloudfront-config" | cut -d= -f2-)
fi
if [ -z "$GUI_BUCKET" ] || [ "$GUI_BUCKET" = "None" ]; then
    GUI_BUCKET=$(aws cloudformation describe-stacks \
        --stack-name "$CF_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='GuiBucketName'].OutputValue" \
        --output text --region "$AWS_REGION" 2>/dev/null || echo "")
fi

empty_s3_bucket_all_versions() {
    local bucket="$1"
    if ! aws s3api head-bucket --bucket "$bucket" --region "$AWS_REGION" 2>/dev/null; then
        echo "  Bucket $bucket does not exist — skipping"
        return
    fi
    echo "Emptying S3 bucket (all versions + delete markers): $bucket"
    # Delete object versions in batches of 1000
    while true; do
        BATCH=$(aws s3api list-object-versions --bucket "$bucket" \
            --query '{Objects: Versions[0:1000].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects":null}')
        COUNT=$(echo "$BATCH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))")
        [ "$COUNT" -eq 0 ] && break
        aws s3api delete-objects --bucket "$bucket" --delete "$BATCH" >/dev/null 2>/dev/null || true
    done
    # Delete delete markers in batches of 1000
    while true; do
        BATCH=$(aws s3api list-object-versions --bucket "$bucket" \
            --query '{Objects: DeleteMarkers[0:1000].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects":null}')
        COUNT=$(echo "$BATCH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('Objects') or []))")
        [ "$COUNT" -eq 0 ] && break
        aws s3api delete-objects --bucket "$bucket" --delete "$BATCH" >/dev/null 2>/dev/null || true
    done
    echo "  Bucket $bucket emptied."
}

if [ -n "$GUI_BUCKET" ] && [ "$GUI_BUCKET" != "None" ]; then
    empty_s3_bucket_all_versions "$GUI_BUCKET"
else
    echo "WARNING: Could not determine GUI bucket name — CloudFormation stack deletion may fail"
fi

# 3b. Empty CloudFront access logs bucket (CloudFormation cannot delete non-empty buckets)
#     Bucket name follows the fixed pattern written by infra.yaml.
LOGS_BUCKET="${PROJECT_NAME}-logs-${ACCOUNT_ID}"
empty_s3_bucket_all_versions "$LOGS_BUCKET"

# 4. Force-delete single ECR repository (CloudFormation cannot delete repos with images)
REPO_NAME="${PROJECT_NAME}"
echo "Force-deleting ECR repository: $REPO_NAME"
aws ecr delete-repository \
    --repository-name "$REPO_NAME" \
    --force \
    --region "$AWS_REGION" 2>/dev/null || true

# 5. Disable CloudFront distribution before stack deletion
#    (OAC cannot be deleted while associated with an enabled distribution)
#    Read from .cloudfront-config first (written by deploy.sh), then fall back to CF outputs.
CF_DIST_ID=""
if [ -f "$SCRIPT_DIR/.cloudfront-config" ]; then
    CF_DIST_ID=$(grep '^CF_DIST_ID=' "$SCRIPT_DIR/.cloudfront-config" | cut -d= -f2-)
fi
if [ -z "$CF_DIST_ID" ] || [ "$CF_DIST_ID" = "None" ]; then
    CF_DIST_ID=$(aws cloudformation describe-stacks \
        --stack-name "$CF_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='GuiCloudFrontDistributionId'].OutputValue" \
        --output text --region "$AWS_REGION" 2>/dev/null || echo "")
fi
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

# 6. Delete CloudFormation stack
#    (removes: IAM role, Cognito, S3 bucket, CloudFront distribution, OAC)
echo "Deleting CloudFormation stack: $CF_STACK_NAME"
aws cloudformation delete-stack \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"

rm -f "$SCRIPT_DIR/.runtime-config"
rm -f "$SCRIPT_DIR/.memory-config"
rm -f "$SCRIPT_DIR/.cloudfront-config"

echo ""
echo "=== Cleanup complete ==="
