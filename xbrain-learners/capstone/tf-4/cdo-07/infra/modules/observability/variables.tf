variable "project"             { type = string }
variable "environment"         { type = string }
variable "aws_region"          { type = string }
variable "budget_limit_usd"    { type = string }
variable "budget_alert_email"  { type = string }
variable "ecs_cluster_name"    { type = string }
variable "kinesis_stream_name" { type = string }
variable "alb_arn_suffix"      { type = string }
