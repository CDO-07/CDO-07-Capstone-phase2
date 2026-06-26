################################################################################
# Layer 4 - Event-Driven Orchestration: Window Feeder
#
# This file now uses the `lambda-scheduled-function` module to create the
# Window Feeder Lambda and its associated EventBridge schedule. The specific
# IAM policy and environment variables are defined here and passed into the
# module.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  project_name = "tf4-foresight-lens"
  environment  = "dev"

  name_prefix = "${local.project_name}-${local.environment}"

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terraform"
    Layer       = "layer4-event-driven-orchestration"
  }

  window_feeder_name = "${local.name_prefix}-window-feeder"
}

variable "window_feeder_package_path" {
  description = "Path to the pre-built Lambda deployment zip for Window Feeder."
  type        = string
  default     = "build/window-feeder.zip"
}

variable "window_feeder_handler" {
  description = "Lambda handler for Window Feeder."
  type        = string
  default     = "app.handler"
}

variable "window_feeder_runtime" {
  description = "Lambda runtime for Window Feeder."
  type        = string
  default     = "python3.12"
}

variable "window_feeder_timeout_seconds" {
  description = "Lambda timeout. Keep below ALB /v1/predict timeout budget."
  type        = number
  default     = 5
}

variable "window_feeder_memory_mb" {
  description = "Lambda memory size."
  type        = number
  default     = 256
}

variable "window_feeder_reserved_concurrency" {
  description = "Reserved concurrency to avoid overlapping feeder runs."
  type        = number
  default     = 1
}

variable "window_feeder_subnet_ids" {
  description = "Private subnet IDs for Lambda when calling an internal ALB. Leave empty for public AWS API-only mode."
  type        = list(string)
  default     = []
}

variable "window_feeder_security_group_ids" {
  description = "Security group IDs for Lambda ENIs when VPC mode is enabled."
  type        = list(string)
  default     = []
}

variable "timestream_database_name" {
  description = "Amazon Timestream database that stores service metrics from the Kinesis ingestion path."
  type        = string
}

variable "timestream_table_name" {
  description = "Amazon Timestream table that stores service metrics from the Kinesis ingestion path."
  type        = string
}

variable "timestream_query_window" {
  description = "Rolling Timestream query window for Window Feeder."
  type        = string
  default     = "2h"
}

variable "ai_engine_predict_url" {
  description = "Internal ALB endpoint for AI Engine prediction, for example http://internal-alb/v1/predict."
  type        = string
}

variable "baseline_s3_bucket_name" {
  description = "S3 bucket that stores model baselines read by the feeder or AI path."
  type        = string
}

variable "audit_s3_bucket_name" {
  description = "S3 bucket where Window Feeder writes audit payloads."
  type        = string
}

variable "audit_s3_prefix" {
  description = "S3 prefix for Window Feeder audit objects."
  type        = string
  default     = "window-feeder/"
}

variable "inference_enabled_parameter_name" {
  description = "SSM parameter used as the operational gate for inference."
  type        = string
  default     = "/tf4/foresight-lens/dev/inference-enabled"
}

variable "drift_alert_sns_topic_arn" {
  description = "SNS topic ARN used for drift and feeder failure alerts."
  type        = string
}

module "window_feeder" {
  source = "./modules/lambda-scheduled-function"

  function_name        = local.window_feeder_name
  function_description = "Queries Timestream over a rolling window, feeds AI Engine, writes audit, and emits drift alerts."
  package_path         = var.window_feeder_package_path
  handler              = var.window_feeder_handler
  runtime              = var.window_feeder_runtime
  timeout_seconds      = var.window_feeder_timeout_seconds
  memory_mb            = var.window_feeder_memory_mb
  reserved_concurrency = var.window_feeder_reserved_concurrency

  subnet_ids         = var.window_feeder_subnet_ids
  security_group_ids = var.window_feeder_security_group_ids

  schedule_expression = var.window_feeder_schedule_expression
  schedule_enabled    = var.window_feeder_schedule_enabled
  event_payload       = var.window_feeder_event_payload

  environment_variables = {
      TIMESTREAM_DATABASE_NAME         = var.timestream_database_name
      TIMESTREAM_TABLE_NAME            = var.timestream_table_name
      TIMESTREAM_QUERY_WINDOW          = var.timestream_query_window
      AI_ENGINE_PREDICT_URL            = var.ai_engine_predict_url
      AI_ENGINE_TIMEOUT_SECONDS        = tostring(var.window_feeder_timeout_seconds)
      BASELINE_S3_BUCKET               = var.baseline_s3_bucket_name
      AUDIT_S3_BUCKET                  = var.audit_s3_bucket_name
      AUDIT_S3_PREFIX                  = var.audit_s3_prefix
      INFERENCE_ENABLED_PARAMETER_NAME = var.inference_enabled_parameter_name
      DRIFT_ALERT_SNS_TOPIC_ARN        = var.drift_alert_sns_topic_arn
  }

  iam_policy_document_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        # The log group ARN is constructed inside the module, so we use a wildcard here.
        # A more secure approach would be to construct the full ARN.
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.window_feeder_name}:*"
      },
      {
        Sid    = "QueryTimestreamWindow"
        Effect = "Allow"
        Action = [
          "timestream:DescribeEndpoints",
          "timestream:Select"
        ]
        Resource = [
          "*",
          "arn:aws:timestream:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${var.timestream_database_name}/table/${var.timestream_table_name}"
        ]
      },
      {
        Sid    = "ReadInferenceGate"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.inference_enabled_parameter_name}"
      },
      {
        Sid    = "ReadBaselines"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.baseline_s3_bucket_name}",
          "arn:aws:s3:::${var.baseline_s3_bucket_name}/*"
        ]
      },
      {
        Sid    = "WriteAuditObjects"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.audit_s3_bucket_name}/${var.audit_s3_prefix}*"
      },
      {
        Sid    = "PublishDriftAlerts"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = var.drift_alert_sns_topic_arn
      },
      {
        Sid      = "ManageVpcNetworkInterfaces"
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface", "ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

output "window_feeder_lambda_name" {
  description = "Window Feeder Lambda function name."
  value       = module.window_feeder.lambda_function_name
}

output "window_feeder_lambda_arn" {
  description = "Window Feeder Lambda function ARN."
  value       = module.window_feeder.lambda_function_arn
}
