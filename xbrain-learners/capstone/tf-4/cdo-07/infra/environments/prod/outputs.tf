output "cost_circuit_breaker_budget_name" {
  description = "Monthly budget name for the cost circuit breaker."
  value       = module.cost_circuit_breaker.budget_name
}

output "cost_circuit_breaker_lambda_name" {
  description = "Lambda function that disables inference at the hard budget threshold."
  value       = module.cost_circuit_breaker.lambda_function_name
}

output "inference_enabled_parameter_name" {
  description = "SSM parameter read by the Window Feeder before AI inference."
  value       = module.cost_circuit_breaker.ssm_parameter_name
}
