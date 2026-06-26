variable "project" {
  description = "Project name prefix to tag and identify resources"
  type        = string
  default     = "tf4-cdo07"
}

variable "environment" {
  description = "Target deployment environment (e.g. staging, prod, sandbox)"
  type        = string
}

variable "sns_topic_name" {
  description = "Custom name for the SNS topic. If not provided, it defaults to {project}-{environment}-slack-alerts"
  type        = string
  default     = null
}

variable "slack_webhook_parameter_name" {
  description = "The name of the SSM Parameter containing the Slack Webhook URL. Strongly recommended for production."
  type        = string
  default     = null
}

variable "slack_webhook_url" {
  description = "Direct Slack Webhook URL. ONLY use for testing. For production, store webhook securely in SSM Parameter Store."
  type        = string
  default     = null
  sensitive   = true
}

variable "kms_key_arn" {
  description = "The KMS key ARN used to decrypt the SSM Parameter if it is a SecureString encrypted with a Customer Managed Key."
  type        = string
  default     = null
}

variable "lambda_function_name" {
  description = "Custom name for the Lambda function. If not provided, it defaults to {project}-{environment}-sns-to-slack"
  type        = string
  default     = null
}
