variable "project" {
  description = "Project prefix used for named AWS resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
}

variable "aws_region" {
  description = "AWS region for regional resources."
  type        = string
}

variable "monthly_budget_limit_usd" {
  description = "Monthly account cost budget limit in USD."
  type        = number
  default     = 200
}

variable "warning_threshold_percent" {
  description = "Budget warning threshold as a percentage of the monthly limit."
  type        = number
  default     = 80
}

variable "hard_threshold_percent" {
  description = "Budget threshold that disables AI inference through the circuit breaker."
  type        = number
  default     = 100
}

variable "ssm_parameter_name" {
  description = "SSM parameter read by the Window Feeder before calling the AI engine."
  type        = string
}

variable "lambda_timeout_seconds" {
  description = "Timeout for the cost circuit breaker Lambda."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the cost circuit breaker Lambda."
  type        = number
  default     = 30
}

variable "warning_email_addresses" {
  description = "Optional email subscribers for the 80 percent budget warning."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags to apply to taggable resources."
  type        = map(string)
  default     = {}
}
