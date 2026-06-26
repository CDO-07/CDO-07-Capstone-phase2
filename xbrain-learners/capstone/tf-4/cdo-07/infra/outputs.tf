###############################################################################
# Root outputs — CDO-07 · Task Force 4
###############################################################################

output "fail_open_fallback_lambda_arn" {
  description = "ARN của Fail-Open Fallback Lambda."
  value       = module.fail_open_fallback.lambda_function_arn
}

output "fail_open_fallback_lambda_name" {
  description = "Tên của Fail-Open Fallback Lambda."
  value       = module.fail_open_fallback.lambda_function_name
}

output "fail_open_fallback_role_arn" {
  description = "IAM Role ARN của Fail-Open Fallback Lambda."
  value       = module.fail_open_fallback.lambda_role_arn
}

output "fail_open_fallback_log_group" {
  description = "CloudWatch Log Group của Fail-Open Fallback Lambda."
  value       = module.fail_open_fallback.log_group_name
}
