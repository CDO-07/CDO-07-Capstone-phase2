output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS name - share with AI team for /v1/predict endpoint"
  value       = module.compute.alb_dns_name
}

output "alb_telemetry_url" {
  description = "Full telemetry ingest URL"
  value       = "http://${module.compute.alb_dns_name}/v1/telemetry"
}

output "alb_predict_url" {
  description = "Full predict URL (AI engine endpoint)"
  value       = "http://${module.compute.alb_dns_name}/v1/predict"
}

output "timestream_database_name" {
  description = "Timestream database name - include in Telemetry Contract"
  value       = module.storage.timestream_database_name
}

output "timestream_table_name" {
  description = "Timestream table name - include in Telemetry Contract"
  value       = module.storage.timestream_table_name
}

output "kinesis_stream_name" {
  description = "Kinesis Data Stream name"
  value       = module.ingest.kinesis_stream_name
}

output "kinesis_stream_arn" {
  description = "Kinesis Data Stream ARN"
  value       = module.ingest.kinesis_stream_arn
}

output "ecs_cluster_name" {
  description = "ECS Cluster name - AI team deploys AI engine here"
  value       = module.compute.ecs_cluster_name
}

output "ecr_ai_engine_repo_url" {
  description = "ECR repo URL for AI Engine image - share with AI team"
  value       = module.compute.ecr_ai_engine_repo_url
}

output "audit_bucket_name" {
  description = "S3 audit log bucket name"
  value       = module.storage.audit_bucket_name
}
