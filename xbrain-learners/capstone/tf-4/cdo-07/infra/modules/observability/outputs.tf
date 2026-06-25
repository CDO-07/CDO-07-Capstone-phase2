output "sns_alerts_arn"   { value = aws_sns_topic.alerts.arn }
output "cost_cb_lambda_arn" { value = aws_lambda_function.cost_cb.arn }
