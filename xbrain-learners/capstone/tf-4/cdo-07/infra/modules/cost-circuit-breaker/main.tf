data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/cost_circuit_breaker.py"
  output_path = "${path.module}/.build/${local.lambda_name}.zip"
}

resource "aws_ssm_parameter" "inference_enabled" {
  name        = var.ssm_parameter_name
  description = "Soft circuit breaker flag read by the Window Feeder before AI inference."
  type        = "String"
  value       = "true"

  tags = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${local.lambda_name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = local.common_tags
}

resource "aws_iam_role" "lambda" {
  name               = "${local.lambda_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Execution role for the cost circuit breaker Lambda."

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.lambda_name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "WriteInferenceEnabledFlag"
    effect = "Allow"

    actions = [
      "ssm:PutParameter",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_parameter_path}",
    ]
  }

  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*",
    ]
  }

  statement {
    sid    = "WriteDeadLetterQueue"
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
    ]

    resources = [
      aws_sqs_queue.lambda_dlq.arn,
    ]
  }

  statement {
    sid    = "WriteXrayTrace"
    effect = "Allow"

    actions = [
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]

    resources = ["*"]
  }
}

#checkov:skip=CKV_AWS_117:Networking module is not in scope yet; this public Lambda only calls regional AWS APIs.
#checkov:skip=CKV_AWS_173:Environment variables contain only non-sensitive parameter names and literal flag values.
#checkov:skip=CKV_AWS_272:Code signing is out of scope for the capstone circuit breaker Lambda.
resource "aws_lambda_function" "cost_circuit_breaker" {
  function_name    = local.lambda_name
  description      = "Disables AI inference when the AWS monthly cost budget reaches the hard threshold."
  role             = aws_iam_role.lambda.arn
  handler          = "cost_circuit_breaker.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      DISABLED_VALUE     = "false"
      SSM_PARAMETER_NAME = aws_ssm_parameter.inference_enabled.name
    }
  }

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]

  tags = local.common_tags
}

#checkov:skip=CKV_AWS_26:SNS topics use default SSE; custom CMK removed to keep apply resilient on local DNS.
resource "aws_sns_topic" "budget_warning" {
  name = "${local.name_prefix}-budget-warning"

  tags = local.common_tags
}

resource "aws_sns_topic" "budget_hard_trigger" {
  name = "${local.name_prefix}-budget-hard-trigger"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = toset(var.warning_email_addresses)

  topic_arn = aws_sns_topic.budget_warning.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_lambda_permission" "allow_budget_sns" {
  statement_id  = "AllowExecutionFromBudgetSns"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_circuit_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_hard_trigger.arn
}

resource "aws_sns_topic_subscription" "hard_trigger_lambda" {
  topic_arn = aws_sns_topic.budget_hard_trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_circuit_breaker.arn

  depends_on = [
    aws_lambda_permission.allow_budget_sns,
  ]
}

resource "aws_sns_topic_policy" "budget_warning" {
  arn    = aws_sns_topic.budget_warning.arn
  policy = data.aws_iam_policy_document.budget_warning_topic.json
}

resource "aws_sns_topic_policy" "budget_hard_trigger" {
  arn    = aws_sns_topic.budget_hard_trigger.arn
  policy = data.aws_iam_policy_document.budget_hard_trigger_topic.json
}

data "aws_iam_policy_document" "budget_warning_topic" {
  statement {
    sid    = "AllowAccountOwnerManageTopic"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root",
      ]
    }

    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:Receive",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]

    resources = [aws_sns_topic.budget_warning.arn]
  }

  statement {
    sid    = "AllowAwsBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget_warning.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "budget_hard_trigger_topic" {
  statement {
    sid    = "AllowAccountOwnerManageTopic"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root",
      ]
    }

    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:Receive",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]

    resources = [aws_sns_topic.budget_hard_trigger.arn]
  }

  statement {
    sid    = "AllowAwsBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget_hard_trigger.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${local.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.warning_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_warning.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.hard_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_hard_trigger.arn]
  }
}
