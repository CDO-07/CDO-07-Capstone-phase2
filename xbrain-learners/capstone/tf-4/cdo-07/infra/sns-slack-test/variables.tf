variable "aws_region" {
  description = "AWS region for test deployment"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for local deployment"
  type        = string
  default     = null
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "tf4-cdo07"
}

variable "environment" {
  description = "Target environment for testing"
  type        = string
  default     = "sandbox"
}

variable "slack_webhook_url" {
  description = "The Slack Webhook URL to store in SSM Parameter Store. (Must be provided to run tests)"
  type        = string
  sensitive   = true
}
