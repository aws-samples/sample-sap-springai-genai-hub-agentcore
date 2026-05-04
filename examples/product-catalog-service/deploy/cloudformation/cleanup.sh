#!/usr/bin/env bash
# ===================================================================
# cleanup.sh — Tear down all resources for product-catalog
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
        export "$key=$val"
    done < "$env_file"
}
if [ -f "$SCRIPT_DIR/.env" ]; then
    load_env "$SCRIPT_DIR/.env"
fi

AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
PROJECT_NAME="${PROJECT_NAME:-product-catalog}"
CF_STACK_NAME="${PROJECT_NAME}-infra"

STAGING_BUCKET=""
if [ -f "$SCRIPT_DIR/.runtime-state" ]; then
    set -a; source "$SCRIPT_DIR/.runtime-state"; set +a
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# Fallback in case .runtime-state is missing
STAGING_BUCKET="${STAGING_BUCKET:-${PROJECT_NAME}-staging-${ACCOUNT_ID}}"

echo "=== Cleanup: $PROJECT_NAME ==="
echo "Region: $AWS_REGION  Stack: $CF_STACK_NAME"
echo ""

# 1. Delete CloudFormation stack
#    (removes: Lambda, Lambda alias/version, API Gateway, IAM role)
#    Note: Lambda versions with DeletionPolicy: Retain are kept.
echo "Deleting CloudFormation stack: $CF_STACK_NAME"
aws cloudformation delete-stack \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"
aws cloudformation wait stack-delete-complete \
    --stack-name "$CF_STACK_NAME" \
    --region "$AWS_REGION"

# 2. Delete staging S3 bucket (not managed by CFN)
if [ -n "$STAGING_BUCKET" ]; then
    echo "Deleting staging bucket: $STAGING_BUCKET"
    aws s3 rb "s3://${STAGING_BUCKET}" --force \
        --region "$AWS_REGION" 2>/dev/null || true
fi

rm -f "$SCRIPT_DIR/.runtime-state"

echo ""
echo "=== Cleanup complete ==="
