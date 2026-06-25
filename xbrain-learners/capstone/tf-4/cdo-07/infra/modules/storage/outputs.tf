output "timestream_database_name" { value = aws_timestreamwrite_database.main.database_name }
output "timestream_table_name"    { value = aws_timestreamwrite_table.metrics.table_name }
output "timestream_table_arn"     { value = aws_timestreamwrite_table.metrics.arn }
output "audit_bucket_name"        { value = aws_s3_bucket.audit.bucket }
output "audit_bucket_arn"         { value = aws_s3_bucket.audit.arn }
output "baseline_bucket_name"     { value = aws_s3_bucket.baseline.bucket }
output "audit_kms_key_arn"        { value = aws_kms_key.audit.arn }
output "ssm_inference_param_name" { value = aws_ssm_parameter.inference_enabled.name }
