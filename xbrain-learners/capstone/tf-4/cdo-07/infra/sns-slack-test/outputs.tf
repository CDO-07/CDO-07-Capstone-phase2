output "sns_topic_arn" {
  description = "The ARN of the test SNS Topic"
  value       = module.sns_to_slack_test.sns_topic_arn
}

output "sns_topic_name" {
  description = "The name of the test SNS Topic"
  value       = module.sns_to_slack_test.sns_topic_name
}

output "ssm_parameter_name" {
  description = "The name of the SSM Parameter holding the Slack Webhook URL"
  value       = aws_ssm_parameter.slack_webhook.name
}

output "lambda_function_arn" {
  description = "The ARN of the test Lambda function"
  value       = module.sns_to_slack_test.lambda_function_arn
}
