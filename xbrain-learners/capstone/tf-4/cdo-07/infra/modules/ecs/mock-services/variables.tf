variable "environment" {
  description = "The environment name (e.g., sandbox, staging, prod)"
  type        = string
  default     = "capstone"
}

variable "vpc_id" {
  description = "The ID of the VPC where target groups will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where ECS tasks will run"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "The security group ID of the ALB to allow ingress traffic to ECS tasks"
  type        = string
}

variable "alb_http_listener_arn" {
  description = "The ARN of the ALB HTTP listener for path-based routing rules"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Capstone"
    Team        = "CDO-07"
  }
}
