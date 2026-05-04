#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# ===================================================================
# cleanup.sh — Tear down all resources for sapaiagent-deployment
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env for PROJECT_NAME / AWS_REGION defaults
# (line-by-line to avoid shell expansion of $, !, | etc. in JSON values)
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
PROJECT_NAME="${PROJECT_NAME:-sapaiagent-deployment}"
CF_STACK_NAME="${PROJECT_NAME}-infra"

# Load runtime state
RUNTIME_ID=""
if [ -f "$SCRIPT_DIR/.runtime-state" ]; then
    set -a; source "$SCRIPT_DIR/.runtime-state"; set +a
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "WARNING: Resources left running will incur ongoing AWS charges. This script will delete all workshop resources."
echo ""
echo "=== Cleanup: $PROJECT_NAME ==="
echo "Region: $AWS_REGION  Stack: $CF_STACK_NAME"
echo ""

# 1. Delete AgentCore runtime and its CloudWatch log group
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

# 2. Empty S3 GUI bucket (CloudFormation cannot delete a non-empty bucket)
GUI_BUCKET="${PROJECT_NAME}-gui-${ACCOUNT_ID}"
echo "Emptying S3 bucket: $GUI_BUCKET"
aws s3 rm "s3://${GUI_BUCKET}" --recursive 2>/dev/null || true
# Remove all object versions and delete markers (required for versioned buckets)
VERSIONS=$(aws s3api list-object-versions --bucket "$GUI_BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects":null}')
if [ "$(echo "$VERSIONS" | jq '.Objects')" != "null" ]; then
    echo "$VERSIONS" | aws s3api delete-objects --bucket "$GUI_BUCKET" --delete file:///dev/stdin 2>/dev/null || true
fi
MARKERS=$(aws s3api list-object-versions --bucket "$GUI_BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects":null}')
if [ "$(echo "$MARKERS" | jq '.Objects')" != "null" ]; then
    echo "$MARKERS" | aws s3api delete-objects --bucket "$GUI_BUCKET" --delete file:///dev/stdin 2>/dev/null || true
fi

# 3. Force-delete ECR repository (CloudFormation cannot delete a repo with images)
ECR_REPO="${PROJECT_NAME}-ecr"
echo "Force-deleting ECR repository: $ECR_REPO"
aws ecr delete-repository \
    --repository-name "$ECR_REPO" \
    --force \
    --region "$AWS_REGION" 2>/dev/null || true

# 4. Disable CloudFront distribution before stack deletion
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

# 5. Empty and delete logging bucket
LOGS_BUCKET="${PROJECT_NAME}-logs-${ACCOUNT_ID}"
echo "Emptying logging bucket: $LOGS_BUCKET"
aws s3 rm "s3://${LOGS_BUCKET}" --recursive 2>/dev/null || true
VERSIONS=$(aws s3api list-object-versions --bucket "$LOGS_BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects":null}')
if [ "$(echo "$VERSIONS" | jq '.Objects')" != "null" ]; then
    echo "$VERSIONS" | aws s3api delete-objects --bucket "$LOGS_BUCKET" --delete file:///dev/stdin 2>/dev/null || true
fi
MARKERS=$(aws s3api list-object-versions --bucket "$LOGS_BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects":null}')
if [ "$(echo "$MARKERS" | jq '.Objects')" != "null" ]; then
    echo "$MARKERS" | aws s3api delete-objects --bucket "$LOGS_BUCKET" --delete file:///dev/stdin 2>/dev/null || true
fi

# 6. Delete CloudFormation stack
#    (removes: IAM role, Cognito user pool, S3 bucket, CloudFront distribution, OAC)
echo "Deleting CloudFormation stack: $CF_STACK_NAME"
aws cloudformation delete-stack \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"

# 7. Clean up local state
rm -f "$SCRIPT_DIR/.runtime-state"

echo ""
echo "=== Cleanup complete ==="
