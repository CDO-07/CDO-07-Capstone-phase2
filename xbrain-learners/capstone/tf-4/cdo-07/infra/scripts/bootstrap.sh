#!/bin/bash
# bootstrap.sh - Run ONCE before first terraform apply
# Creates S3 state bucket + DynamoDB lock table
# Usage: bash scripts/bootstrap.sh

set -euo pipefail

PROJECT="tf4-cdo07"
REGION="ap-southeast-1"
STATE_BUCKET="${PROJECT}-tf-state"
LOCK_TABLE="${PROJECT}-tf-lock"

echo "==> Bootstrapping Terraform state backend for ${PROJECT}"
echo "    Region: ${REGION}"
echo "    State bucket: ${STATE_BUCKET}"
echo "    Lock table: ${LOCK_TABLE}"

# Create S3 state bucket
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo "✅ S3 bucket ${STATE_BUCKET} already exists"
else
  echo "--> Creating S3 bucket ${STATE_BUCKET}..."
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  aws s3api put-bucket-versioning \
    --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

  aws s3api put-public-access-block \
    --bucket "${STATE_BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "✅ S3 bucket created and configured"
fi

# Create DynamoDB lock table
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${REGION}" 2>/dev/null; then
  echo "✅ DynamoDB table ${LOCK_TABLE} already exists"
else
  echo "--> Creating DynamoDB lock table ${LOCK_TABLE}..."
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  aws dynamodb wait table-exists \
    --table-name "${LOCK_TABLE}" \
    --region "${REGION}"

  echo "✅ DynamoDB lock table created"
fi

echo ""
echo "==> Bootstrap complete! Now run:"
echo "    cd infra"
echo "    terraform init"
echo "    terraform plan -var-file=environments/sandbox/terraform.tfvars"
echo "    terraform apply -var-file=environments/sandbox/terraform.tfvars"
