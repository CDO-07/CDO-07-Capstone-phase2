terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  sns_topic_name = var.sns_topic_name != null ? var.sns_topic_name : "${var.project}-${var.environment}-slack-alerts"
  lambda_name    = var.lambda_function_name != null ? var.lambda_function_name : "${var.project}-${var.environment}-sns-to-slack"
}

# 1. Package the Lambda Python script
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda/lambda_function.zip"
}

# 2. SNS Topic
# checkov:skip=CKV_AWS_26: SNS topic is encrypted using AWS managed key 'alias/aws/sns' by default to secure data at rest.
resource "aws_sns_topic" "alerts" {
  name              = local.sns_topic_name
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name        = local.sns_topic_name
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# 3. IAM Execution Role for Lambda
resource "aws_iam_role" "lambda" {
  name = "${local.lambda_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# Attach basic execution policy for CloudWatch Logging
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy to read SSM Parameter Store and Decrypt KMS
resource "aws_iam_policy" "lambda_ssm" {
  count       = var.slack_webhook_parameter_name != null ? 1 : 0
  name        = "${local.lambda_name}-ssm-policy"
  description = "Allow Lambda to read Slack Webhook secure parameters from SSM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.slack_webhook_parameter_name}"
        }
      ],
      var.kms_key_arn != null ? [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.kms_key_arn
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ssm" {
  count      = var.slack_webhook_parameter_name != null ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_ssm[0].arn
}

# 4. Lambda Function
# checkov:skip=CKV_AWS_116: Dead Letter Queue (DLQ) not required as SNS topic handles retry behaviors.
# checkov:skip=CKV_AWS_173: Environment variables do not leak active secrets; fallback test variable is marked sensitive in variables and used only in sandbox environments.
# checkov:skip=CKV_AWS_50: CloudWatch X-Ray tracing is disabled for budget conservation in sandbox/staging.
# checkov:skip=CKV_AWS_272: Code signing is not mandated for this internal routing utility.
resource "aws_lambda_function" "sns_to_slack" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = local.lambda_name
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  timeout          = 15

  environment {
    variables = {
      SLACK_WEBHOOK_URL            = var.slack_webhook_url
      SLACK_WEBHOOK_PARAMETER_NAME = var.slack_webhook_parameter_name
    }
  }

  tags = {
    Name        = local.lambda_name
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# 5. CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = 7

  tags = {
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# 6. Lambda permissions to allow SNS invocation
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sns_to_slack.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# 7. SNS Subscription
resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.sns_to_slack.arn
}
