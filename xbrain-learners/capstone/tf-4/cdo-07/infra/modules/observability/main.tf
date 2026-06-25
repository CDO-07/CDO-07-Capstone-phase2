# ─────────────────────────────────────────────────────────────────────────────
# Module: observability
# Creates: CloudWatch Alarms, AWS Budgets + Lambda Cost Circuit Breaker
# ─────────────────────────────────────────────────────────────────────────────

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────

# Kinesis: IteratorAge > 60s = consumer lag (ingest falling behind)
resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name          = "${var.project}-kinesis-iterator-age"
  alarm_description   = "Kinesis consumer lag > 60s - ingest worker falling behind"
  namespace           = "AWS/Kinesis"
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  dimensions          = { StreamName = var.kinesis_stream_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 60000 # 60 seconds in ms
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${var.project}-kinesis-lag-alarm" }
}

# ECS AI Engine: CPU > 80%
resource "aws_cloudwatch_metric_alarm" "ai_engine_cpu" {
  alarm_name          = "${var.project}-ai-engine-cpu-high"
  alarm_description   = "AI Engine CPU > 80%"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = "${var.project}-ai-engine"
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${var.project}-ai-engine-cpu-alarm" }
}

# ALB: 5XX error rate > 5%
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx-high"
  alarm_description   = "ALB 5XX error rate > 5%"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${var.project}-alb-5xx-alarm" }
}

# ── SNS Topic cho alerts ──────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  tags = { Name = "${var.project}-alerts-topic" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

# ── AWS Budgets (Cost Circuit Breaker) ────────────────────────────────────────
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80 # alert at 80% = $160
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100 # alert at 100% = $200
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}

# ── Lambda Cost Circuit Breaker ───────────────────────────────────────────────
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_cb" {
  name               = "${var.project}-lambda-cb-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_cb_policy" {
  statement {
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:*:*:parameter/${var.project}/*/inference_enabled"]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "lambda_cb" {
  name   = "${var.project}-lambda-cb-policy"
  role   = aws_iam_role.lambda_cb.id
  policy = data.aws_iam_policy_document.lambda_cb_policy.json
}

data "archive_file" "cost_cb" {
  type        = "zip"
  output_path = "${path.module}/lambda_cb.zip"
  source {
    content  = <<-PYTHON
import boto3, os, json, logging

logger   = logging.getLogger()
logger.setLevel(logging.INFO)
ssm      = boto3.client("ssm")
sns      = boto3.client("sns")
PROJECT  = os.environ["PROJECT"]
ENV      = os.environ["ENVIRONMENT"]
SNS_ARN  = os.environ["SNS_ALERT_ARN"]

def handler(event, context):
    """
    Triggered by AWS Budgets SNS alert when spend > $180 (90% of $200).
    Sets inference_enabled = false to stop Bedrock calls.
    """
    logger.warning(f"Budget threshold exceeded. Disabling AI inference. Event: {event}")

    try:
        ssm.put_parameter(
            Name=f"/{PROJECT}/{ENV}/inference_enabled",
            Value="false",
            Type="String",
            Overwrite=True
        )
        sns.publish(
            TopicArn=SNS_ARN,
            Subject=f"[COST CIRCUIT BREAKER] {PROJECT} AI inference DISABLED",
            Message=f"Budget threshold exceeded. inference_enabled set to false.\n"
                    f"AI engine will use fail-open fallback (static thresholds).\n"
                    f"Re-enable manually: aws ssm put-parameter --name /{PROJECT}/{ENV}/inference_enabled --value true --overwrite"
        )
        return {"status": "circuit_breaker_activated", "inference_enabled": False}
    except Exception as e:
        logger.error(f"Failed to activate circuit breaker: {e}")
        raise
PYTHON
    filename = "lambda_cb.py"
  }
}

resource "aws_cloudwatch_log_group" "lambda_cb" {
  name              = "/aws/lambda/${var.project}-cost-cb"
  retention_in_days = 14
}

resource "aws_lambda_function" "cost_cb" {
  function_name    = "${var.project}-cost-circuit-breaker"
  role             = aws_iam_role.lambda_cb.arn
  runtime          = "python3.13"
  handler          = "lambda_cb.handler"
  filename         = data.archive_file.cost_cb.output_path
  source_code_hash = data.archive_file.cost_cb.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      PROJECT         = var.project
      ENVIRONMENT     = var.environment
      SNS_ALERT_ARN   = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_cb]
  tags       = { Name = "${var.project}-cost-cb" }
}

# Allow SNS to invoke Lambda CB
resource "aws_lambda_permission" "sns_to_cb" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_cb.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "cost_cb" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_cb.arn
}
