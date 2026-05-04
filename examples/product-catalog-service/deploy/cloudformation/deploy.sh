#!/usr/bin/env bash
# ===================================================================
# deploy.sh — Deploy Product Catalog Service (Lambda + API Gateway)
#
# Usage:
#   cp deploy/cloudformation/.env.example deploy/cloudformation/.env
#   # Edit .env with your values
#   ./deploy/cloudformation/deploy.sh
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# ===================================================================
# Configuration
# ===================================================================
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
PROJECT_NAME="${PROJECT_NAME:-product-catalog}"
CF_STACK_NAME="${PROJECT_NAME}-infra"
STAGING_BUCKET="${PROJECT_NAME}-staging-${AWS_ACCOUNT_ID}"

: "${PRODUCT_CATALOG_API_KEY:?Set PRODUCT_CATALOG_API_KEY in deploy/cloudformation/.env}"

echo "================================================================="
echo " Product Catalog Service — Lambda + API Gateway"
echo " Region:   $AWS_REGION"
echo " Account:  $AWS_ACCOUNT_ID"
echo " Project:  $PROJECT_NAME"
echo "================================================================="

# ===================================================================
# Step 1: Build JAR
# ===================================================================
echo ""
echo ">>> Step 1: Building JAR..."
cd "$PROJECT_ROOT"
./mvnw clean package -DskipTests -ntp

JAR_FILE=$(ls "$PROJECT_ROOT/target/product-catalog-service-"*.jar 2>/dev/null | head -1 || echo "")
if [ -z "$JAR_FILE" ]; then
    echo "ERROR: JAR not found in $PROJECT_ROOT/target/"
    exit 1
fi
echo "JAR: $JAR_FILE"

# ===================================================================
# Step 2: Upload JAR to staging S3 bucket
# CloudFormation Lambda resources require code in S3.
# ===================================================================
echo ""
echo ">>> Step 2: Uploading JAR to S3 staging bucket..."

# Create staging bucket if it doesn't exist
if ! aws s3api head-bucket --bucket "$STAGING_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    echo "  Creating staging bucket: $STAGING_BUCKET"
    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$STAGING_BUCKET" \
            --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket \
            --bucket "$STAGING_BUCKET" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
fi

aws s3 cp "$JAR_FILE" "s3://${STAGING_BUCKET}/product-catalog-service.jar" --quiet
echo "  Uploaded to s3://${STAGING_BUCKET}/product-catalog-service.jar"

# ===================================================================
# Step 3: Deploy CloudFormation
# ===================================================================
echo ""
echo ">>> Step 3: Deploying CloudFormation stack..."

aws cloudformation deploy \
    --template-file "$SCRIPT_DIR/infra.yaml" \
    --stack-name "$CF_STACK_NAME" \
    --parameter-overrides \
        ProjectName="$PROJECT_NAME" \
        ApiKey="$PRODUCT_CATALOG_API_KEY" \
        CodeS3Bucket="$STAGING_BUCKET" \
        CodeS3Key="product-catalog-service.jar" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --region "$AWS_REGION"

read_output() {
    aws cloudformation describe-stacks \
        --stack-name "$CF_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
        --output text --region "$AWS_REGION"
}

PRODUCT_CATALOG_URL=$(read_output ProductCatalogUrl)
LAMBDA_FUNCTION=$(read_output LambdaFunctionName)

echo "Lambda:      $LAMBDA_FUNCTION"
echo "URL:         $PRODUCT_CATALOG_URL"

# ===================================================================
# Step 4: Smoke test
# ===================================================================
echo ""
echo ">>> Step 4: Smoke test (Lambda cold start may take ~10s)..."
sleep 10
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "x-api-key: $PRODUCT_CATALOG_API_KEY" \
    "${PRODUCT_CATALOG_URL}/products" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    echo "  OK — API responding (HTTP $HTTP_CODE)"
else
    echo "  WARNING: Got HTTP $HTTP_CODE — Lambda may still be initializing (SnapStart)"
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "================================================================="
echo " DEPLOYMENT COMPLETE"
echo "================================================================="
echo ""
echo " Product Catalog URL: $PRODUCT_CATALOG_URL"
echo ""
echo " Test with:"
echo "   curl -H \"x-api-key: $PRODUCT_CATALOG_API_KEY\" ${PRODUCT_CATALOG_URL}/products"
echo "   curl -H \"x-api-key: $PRODUCT_CATALOG_API_KEY\" ${PRODUCT_CATALOG_URL}/v3/api-docs"
echo ""
echo " Next: Set PRODUCT_CATALOG_URL=$PRODUCT_CATALOG_URL"
echo "       when deploying the gateway example."
echo ""

cat > "$SCRIPT_DIR/.runtime-state" <<EOFSTATE
CF_STACK_NAME=${CF_STACK_NAME}
PRODUCT_CATALOG_URL=${PRODUCT_CATALOG_URL}
PRODUCT_CATALOG_API_KEY=${PRODUCT_CATALOG_API_KEY}
STAGING_BUCKET=${STAGING_BUCKET}
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
EOFSTATE

echo "State saved to deploy/cloudformation/.runtime-state"
