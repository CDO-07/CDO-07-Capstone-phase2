output "budget_name" {
  description = "AWS Budgets monthly cost budget name."
  value       = aws_budgets_budget.monthly_cost.name
}

output "lambda_function_name" {
  description = "Cost circuit breaker Lambda function name."
  value       = aws_lambda_function.cost_circuit_breaker.function_name
}

output "lambda_function_arn" {
  description = "Cost circuit breaker Lambda function ARN."
  value       = aws_lambda_function.cost_circuit_breaker.arn
}

output "ssm_parameter_name" {
  description = "SSM parameter toggled by the cost circuit breaker."
  value       = aws_ssm_parameter.inference_enabled.name
}

output "budget_warning_topic_arn" {
  description = "SNS topic used for budget warning notifications."
  value       = aws_sns_topic.budget_warning.arn
}

output "budget_hard_trigger_topic_arn" {
  description = "SNS topic that invokes the circuit breaker Lambda at the hard budget threshold."
  value       = aws_sns_topic.budget_hard_trigger.arn
}
