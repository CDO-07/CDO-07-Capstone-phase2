###############################################################################
# Outputs — Module: fail-open-fallback
###############################################################################

output "lambda_function_arn" {
  description = "ARN của Fail-Open Fallback Lambda function."
  value       = aws_lambda_function.fallback.arn
}

output "lambda_function_name" {
  description = "Tên của Fail-Open Fallback Lambda function."
  value       = aws_lambda_function.fallback.function_name
}

output "lambda_role_arn" {
  description = "ARN của IAM Execution Role được gắn với Lambda."
  value       = aws_iam_role.fallback.arn
}

output "lambda_role_name" {
  description = "Tên của IAM Execution Role."
  value       = aws_iam_role.fallback.name
}

output "log_group_name" {
  description = "Tên CloudWatch Log Group của Lambda."
  value       = aws_cloudwatch_log_group.fallback.name
}

output "cloudwatch_alarm_arn" {
  description = "ARN CloudWatch Alarm giám sát lỗi của Fallback Lambda."
  value       = aws_cloudwatch_metric_alarm.fallback_errors.arn
}
