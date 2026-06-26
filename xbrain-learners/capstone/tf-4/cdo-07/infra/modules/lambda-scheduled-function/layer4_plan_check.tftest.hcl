# File nay chua cac bai test tinh (plan test) cho ha tang Layer 4.
# No su dung Terraform Test Framework (native HCL) de kiem tra ket qua
# cua `terraform plan` ma khong can trien khai tai nguyen thuc te.

# Dinh nghia cac bien dau vao can thiet de chay `terraform plan`.
# Chung ta cung cap cac gia tri gia lap de test chay doc lap.
variables {
  timestream_database_name  = "test-metrics-db"
  timestream_table_name     = "service-metrics"
  ai_engine_predict_url     = "http://test.local/predict"
  baseline_s3_bucket_name   = "test-baseline-bucket"
  audit_s3_bucket_name      = "test-audit-bucket"
  drift_alert_sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-drift-topic"
}

# Khoi `run` dinh nghia mot kịch ban test.
# O day, chung ta chay `terraform plan` va kiem tra ket qua.
run "plan_check_layer4_configurations" {

  # Chi dinh lenh can chay. `plan` la lenh de kiem thu tinh.
  command = plan

  # Cac khoi `assert` se kiem tra cac dieu kien trong plan.
  # Neu bat ky dieu kien nao sai, test se that bai.

  # --- Test 1: Kiem tra cau hinh co ban cua Lambda Function ---
  assert {
    condition     = module.window_feeder.aws_lambda_function.this.runtime == "python3.12"
    error_message = "Lambda runtime phai la 'python3.12'."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.handler == "app.handler"
    error_message = "Lambda handler phai la 'app.handler'."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.memory_size == 256
    error_message = "Lambda memory size phai la 256MB."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.timeout == 5
    error_message = "Lambda timeout phai la 5 giay."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.reserved_concurrent_executions == 1
    error_message = "Lambda reserved concurrency phai la 1."
  }

  # --- Test 2: Kiem tra cau hinh cua EventBridge Schedule Rule ---
  assert {
    condition     = module.window_feeder.aws_cloudwatch_event_rule.schedule.schedule_expression == "rate(5 minutes)"
    error_message = "EventBridge schedule expression phai la 'rate(5 minutes)'."
  }

  assert {
    condition     = module.window_feeder.aws_cloudwatch_event_rule.schedule.state == "ENABLED"
    error_message = "EventBridge rule phai duoc bat (ENABLED)."
  }

  # --- Test 3: Kiem tra EventBridge Target co tro dung den Lambda khong ---
  assert {
    condition     = module.window_feeder.aws_cloudwatch_event_target.lambda.arn == module.window_feeder.aws_lambda_function.this.arn
    error_message = "EventBridge target ARN phai tro den ARN cua Lambda function."
  }

  # --- Test 4: Kiem tra cac bien moi truong cua Lambda ---
  assert {
    condition     = module.window_feeder.aws_lambda_function.this.environment[0].variables.TIMESTREAM_DATABASE_NAME == var.timestream_database_name
    error_message = "Bien moi truong TIMESTREAM_DATABASE_NAME khong duoc thiet lap dung."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.environment[0].variables.TIMESTREAM_TABLE_NAME == var.timestream_table_name
    error_message = "Bien moi truong TIMESTREAM_TABLE_NAME khong duoc thiet lap dung."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.environment[0].variables.AI_ENGINE_PREDICT_URL == var.ai_engine_predict_url
    error_message = "Bien moi truong AI_ENGINE_PREDICT_URL khong duoc thiet lap dung."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.environment[0].variables.DRIFT_ALERT_SNS_TOPIC_ARN == var.drift_alert_sns_topic_arn
    error_message = "Bien moi truong DRIFT_ALERT_SNS_TOPIC_ARN khong duoc thiet lap dung."
  }

  assert {
    condition     = module.window_feeder.aws_lambda_function.this.environment[0].variables.TIMESTREAM_QUERY_WINDOW == "2h"
    error_message = "Bien moi truong TIMESTREAM_QUERY_WINDOW phai la '2h'."
  }

  # --- Test 5: Kiem tra cac quyen quan trong trong IAM Policy ---
  # Do policy la mot chuoi JSON, chung ta su dung ham `contains` de kiem tra su ton tai
  # cua cac Action va Resource quan trong.
  assert {
    condition = contains(
      jsondecode(module.window_feeder.aws_iam_role_policy.lambda.policy).Statement[*].Action,
      ["timestream:DescribeEndpoints", "timestream:Select"]
    )
    error_message = "IAM policy phai chua cac quyen de truy van Timestream."
  }

  assert {
    condition = contains(
      jsondecode(module.window_feeder.aws_iam_role_policy.lambda.policy).Statement[*].Action,
      ["ssm:GetParameter"]
    )
    error_message = "IAM policy phai chua quyen ssm:GetParameter."
  }

  assert {
    condition = contains(
      jsondecode(module.window_feeder.aws_iam_role_policy.lambda.policy).Statement[*].Action,
      ["s3:PutObject"]
    )
    error_message = "IAM policy phai chua quyen s3:PutObject."
  }

  assert {
    condition = contains(
      jsondecode(module.window_feeder.aws_iam_role_policy.lambda.policy).Statement[*].Action,
      ["sns:Publish"]
    )
    error_message = "IAM policy phai chua quyen sns:Publish."
  }
}
