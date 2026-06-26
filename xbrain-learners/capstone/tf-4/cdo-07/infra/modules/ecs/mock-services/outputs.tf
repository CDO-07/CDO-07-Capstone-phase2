output "cluster_arn" {
  description = "The ARN of the ECS cluster"
  value       = module.ecs_cluster.cluster_arn
}

output "payment_service_id" {
  description = "The ID of the Payment GW ECS service"
  value       = module.payment_gw.id
}

output "fraud_service_id" {
  description = "The ID of the Fraud Detection ECS service"
  value       = module.fraud_detection.id
}

output "ledger_service_id" {
  description = "The ID of the Ledger Svc ECS service"
  value       = module.ledger_svc.id
}
