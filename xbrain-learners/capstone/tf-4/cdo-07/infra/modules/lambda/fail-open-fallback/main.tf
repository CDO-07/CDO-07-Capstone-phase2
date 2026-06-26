###############################################################################
# Module: fail-open-fallback
# Mô tả : Lambda kích hoạt khi AI Engine timeout hoặc Window Feeder thất bại,
#         đánh giá metric theo ngưỡng tĩnh, publish SNS alert, push Grafana
#         annotation, và ghi audit log S3.
# Kiến trúc: ADR-001 Fail-Open Fallback (03_security_design.md §2.1)
###############################################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  function_name = "${var.project}-${var.environment}-fail-open-fallback"
  log_group     = "/aws/lambda/${local.function_name}"
}

# ---------------------------------------------------------------------------
# 1. Package Lambda source code
# ---------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/fallback_handler.py"
  output_path = "${path.module}/lambda/fallback_handler.zip"
}

# ---------------------------------------------------------------------------
# 2. IAM Execution Role — least-privilege (per ADR-001 + 03_security_design)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "fallback" {
  name        = "${local.function_name}-role"
  description = "Execution role for Fail-Open Fallback Lambda — CDO-07 TF4"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# Basic execution: CloudWatch Logs
resource "aws_iam_role_policy_attachment" "fallback_basic_exec" {
  role       = aws_iam_role.fallback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy: SNS publish + S3 audit write + SSM read + CloudWatch GetMetric
resource "aws_iam_policy" "fallback" {
  name        = "${local.function_name}-policy"
  description = "Least-privilege policy for Fail-Open Fallback Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SNS: chỉ publish lên topic alert, không có quyền manage topic
      {
        Sid    = "AllowSNSPublishAlert"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [var.alert_sns_topic_arn]
      },
      # S3: ghi audit log vào prefix cụ thể
      {
        Sid    = "AllowS3AuditWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
        ]
        Resource = ["${var.audit_s3_bucket_arn}/${var.audit_s3_prefix}*"]
      },
      # SSM: đọc Grafana API key (SecureString)
      {
        Sid    = "AllowSSMReadGrafanaKey"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.grafana_api_key_parameter}"
        ]
      },
      # KMS: giải mã SecureString từ SSM
      {
        Sid    = "AllowKMSDecryptForSSM"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = [var.kms_key_arn]
      },
      # CloudWatch: đọc metric để đánh giá ngưỡng tĩnh
      {
        Sid    = "AllowCloudWatchReadMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = ["*"]
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "fallback_custom" {
  role       = aws_iam_role.fallback.name
  policy_arn = aws_iam_policy.fallback.arn
}

# ---------------------------------------------------------------------------
# 3. CloudWatch Log Group — 7 ngày retention (per 03_security_design §5.2)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "fallback" {
  name              = local.log_group
  retention_in_days = 7

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 4. Lambda Function
# ---------------------------------------------------------------------------
# checkov:skip=CKV_AWS_116: DLQ không cần thiết — SNS trigger có retry built-in; lỗi được ghi vào CloudWatch Logs và S3 audit.
# checkov:skip=CKV_AWS_50:  X-Ray tracing tắt để tiết kiệm chi phí capstone.
# checkov:skip=CKV_AWS_272: Code signing không bắt buộc cho internal utility Lambda.
resource "aws_lambda_function" "fallback" {
  function_name    = local.function_name
  description      = "Fail-Open Fallback: đánh giá ngưỡng tĩnh khi AI Engine không khả dụng"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.fallback.arn
  handler          = "fallback_handler.handler"
  runtime          = "python3.11"
  timeout          = 30

  environment {
    variables = {
      LOG_LEVEL                  = var.log_level
      ALERT_SNS_TOPIC_ARN        = var.alert_sns_topic_arn
      AUDIT_S3_BUCKET            = var.audit_s3_bucket_name
      AUDIT_S3_PREFIX            = var.audit_s3_prefix
      GRAFANA_HOST               = var.grafana_host
      GRAFANA_API_KEY_PARAMETER  = var.grafana_api_key_parameter
      GRAFANA_DASHBOARD_UID      = var.grafana_dashboard_uid
      THRESHOLD_CPU_PCT          = tostring(var.threshold_cpu_pct)
      THRESHOLD_MEMORY_PCT       = tostring(var.threshold_memory_pct)
      THRESHOLD_ALB_CONNECTIONS  = tostring(var.threshold_alb_connections)
      THRESHOLD_QUEUE_DEPTH      = tostring(var.threshold_queue_depth)
    }
  }

  # Đảm bảo log group tồn tại trước khi Lambda được tạo
  depends_on = [
    aws_cloudwatch_log_group.fallback,
    aws_iam_role_policy_attachment.fallback_basic_exec,
    aws_iam_role_policy_attachment.fallback_custom,
  ]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 5. SNS Trigger — subscribe vào topic "window-feeder-failed"
#    Window Feeder publish lên topic này khi gặp lỗi
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "allow_sns_trigger" {
  statement_id  = "AllowSNSTriggerFallback"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fallback.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.window_feeder_failure_sns_arn
}

resource "aws_sns_topic_subscription" "fallback_trigger" {
  topic_arn = var.window_feeder_failure_sns_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.fallback.arn
}

# ---------------------------------------------------------------------------
# 6. CloudWatch Alarm — monitor chính Lambda Fallback
#    Cảnh báo nếu chính Lambda Fallback bị lỗi liên tục
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "fallback_errors" {
  alarm_name          = "${local.function_name}-errors"
  alarm_description   = "Fail-Open Fallback Lambda gặp lỗi liên tiếp — cần kiểm tra ngay"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.fallback.function_name
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_sns_topic_arn]
  ok_actions          = [var.alert_sns_topic_arn]

  tags = var.tags
}
