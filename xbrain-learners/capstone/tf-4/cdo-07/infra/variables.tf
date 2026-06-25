variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "sandbox"
}

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "tf4-cdo07"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.4.7.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for public subnet (ALB + Grafana)"
  type        = string
  default     = "10.4.7.0/24"
}

variable "private_app_subnet_cidr" {
  description = "CIDR for private app subnet (ECS tasks)"
  type        = string
  default     = "10.4.8.0/24"
}

variable "private_data_subnet_cidr" {
  description = "CIDR for private data subnet (Timestream, Audit)"
  type        = string
  default     = "10.4.9.0/24"
}

# ── Compute ───────────────────────────────────────────────────────────────────
variable "mock_service_image" {
  description = "Container image for mock microservices (Node.js placeholder)"
  type        = string
  default     = "public.ecr.aws/docker/library/node:20-alpine"
}

variable "ai_engine_image" {
  description = "Container image for AI Engine (skeleton, replaced by AI team)"
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.13-slim"
}

# ── Kinesis ───────────────────────────────────────────────────────────────────
variable "kinesis_shard_count" {
  description = "Number of shards for Kinesis Data Stream (provisioned)"
  type        = number
  default     = 2
}

variable "kinesis_retention_hours" {
  description = "Kinesis stream retention period in hours"
  type        = number
  default     = 24
}

# ── Timestream ────────────────────────────────────────────────────────────────
variable "timestream_memory_hours" {
  description = "Timestream memory store retention in hours"
  type        = number
  default     = 48 # 2 days hot query for AI engine
}

variable "timestream_magnetic_days" {
  description = "Timestream magnetic store retention in days"
  type        = number
  default     = 90 # minimum per TF4 spec
}

# ── Budget ────────────────────────────────────────────────────────────────────
variable "budget_limit_usd" {
  description = "Monthly AWS budget limit in USD for cost circuit breaker"
  type        = string
  default     = "200"
}

variable "budget_alert_email" {
  description = "Email to receive budget alerts"
  type        = string
  default     = "team-cdo07@example.com" # TODO: replace with real email
}
