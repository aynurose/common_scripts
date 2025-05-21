#!/bin/bash
TFVARS_FILE="$1"
AWS_PROFILE="${2:-default}"  # Use 'default' if not specified

# Check if AWS CLI is installed
if ! command -v aws >/dev/null 2>&1; then
  echo "❌ Error: AWS CLI is not installed. Please install it and try again."
  return 1
fi

# Function to extract variables from tfvars
extract_var() {
  local var_name=$1
  grep -E "^$var_name" "$TFVARS_FILE" | awk -F'=' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/#.*$/, "", $2); gsub(/"/, "", $2); print $2}' | tr -d ' '
}

# Load variables from tfvars or fallback to environment
if [[ -n "$TFVARS_FILE" && -f "$TFVARS_FILE" ]]; then
  echo "✅ Loading values from tfvars file: $TFVARS_FILE"
  BUCKET_NAME=$(extract_var "aws_bucket_name")
  DEPLOYMENT_NAME=$(extract_var "deployment_name")
  DEPLOYMENT_ENVIRONMENT=$(extract_var "deployment_environment")
  AWS_BUCKET_REGION=$(extract_var "aws_bucket_region")
else
  echo "⚙️ No tfvars file provided. Falling back to environment variables or default values."
  BUCKET_NAME="${AWS_BUCKET_NAME}"
  DEPLOYMENT_NAME="${DEPLOYMENT_NAME}"
  DEPLOYMENT_ENVIRONMENT="${DEPLOYMENT_ENVIRONMENT}"
  AWS_BUCKET_REGION="${AWS_BUCKET_REGION}"
fi

# Check that all required variables are set
if [[ -z "$BUCKET_NAME" || -z "$DEPLOYMENT_NAME" || -z "$DEPLOYMENT_ENVIRONMENT" || -z "$AWS_BUCKET_REGION" ]]; then
  echo "❌ Error: One or more required variables are missing."
  echo "Expected variables: aws_bucket_name, deployment_name, deployment_environment, aws_bucket_region"
  return 1
fi

# Check for valid AWS credentials
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
  if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo "❌ Error: No valid AWS credentials found for profile: $AWS_PROFILE"
    echo "Provide credentials via AWS profile or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
    return 1
  fi
fi

# Check or create S3 bucket
echo "🔍 Checking if the S3 bucket '$BUCKET_NAME' exists..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
  echo "✅ S3 bucket '$BUCKET_NAME' already exists."
else
  echo "🚀 Creating S3 bucket '$BUCKET_NAME' in region '$AWS_BUCKET_REGION'..."
  if ! aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_BUCKET_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_BUCKET_REGION" \
      --profile "$AWS_PROFILE"; then
    echo "❌ Failed to create the S3 bucket."
    return 1
  fi
  echo "✅ S3 bucket created."
fi

# Create folder (prefix) inside the bucket
PREFIX_PATH="$DEPLOYMENT_NAME/$DEPLOYMENT_ENVIRONMENT/"
echo "📁 Creating prefix '$PREFIX_PATH' in bucket '$BUCKET_NAME'..."
if ! aws s3api put-object --bucket "$BUCKET_NAME" --key "$PREFIX_PATH" --profile "$AWS_PROFILE"; then
  echo "❌ Error: Failed to create prefix path."
  return 1
else
  echo "✅ Prefix created successfully."
fi

# Write backend.tf
cat <<EOF > backend.tf
terraform {
  backend "s3" {
    bucket = "$BUCKET_NAME"
    key    = "$DEPLOYMENT_NAME/$DEPLOYMENT_ENVIRONMENT/terraform.tfstate"
    region = "$AWS_BUCKET_REGION"
  }
}
EOF

echo "📝 backend.tf file created successfully."

# Initialize Terraform
terraform init