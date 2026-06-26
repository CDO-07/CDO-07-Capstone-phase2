output "sns_topic_arn" {
  description = "The ARN of the SNS Topic"
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "The name of the SNS Topic"
  value       = aws_sns_topic.alerts.name
}

output "lambda_function_arn" {
  description = "The ARN of the Lambda function forwarding alerts to Slack"
  value       = aws_lambda_function.sns_to_slack.arn
}

output "lambda_role_arn" {
  description = "The ARN of the IAM Execution Role for Lambda"
  value       = aws_iam_role.lambda.arn
}
