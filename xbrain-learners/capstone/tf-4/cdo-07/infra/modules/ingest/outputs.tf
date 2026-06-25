output "kinesis_stream_name" { value = aws_kinesis_stream.metrics.name }
output "kinesis_stream_arn"  { value = aws_kinesis_stream.metrics.arn }
output "dlq_url"             { value = aws_sqs_queue.dlq.url }
output "transformer_arn"     { value = aws_lambda_function.transformer.arn }
