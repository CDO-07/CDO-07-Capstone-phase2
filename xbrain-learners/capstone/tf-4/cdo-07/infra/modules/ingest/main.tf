# ─────────────────────────────────────────────────────────────────────────────
# Module: ingest
# Creates: Kinesis Data Stream, Kinesis Firehose, Lambda Transformer (PII drop)
# ─────────────────────────────────────────────────────────────────────────────

# ── Kinesis Data Stream (provisioned shards) ──────────────────────────────────
resource "aws_kinesis_stream" "metrics" {
  name             = "${var.project}-metrics-stream"
  shard_count      = var.kinesis_shard_count
  retention_period = var.kinesis_retention_hours

  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "IteratorAgeMilliseconds",
    "OutgoingBytes",
    "OutgoingRecords",
  ]

  tags = { Name = "${var.project}-metrics-stream" }
}

# ── IAM Role cho Lambda Transformer ──────────────────────────────────────────
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_transformer" {
  name               = "${var.project}-lambda-transformer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_transformer_policy" {
  # Kinesis read
  statement {
    actions = [
      "kinesis:GetRecords",
      "kinesis:GetShardIterator",
      "kinesis:DescribeStream",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.metrics.arn]
  }
  # Timestream write
  statement {
    actions   = ["timestream:WriteRecords", "timestream:DescribeEndpoints"]
    resources = [var.timestream_table_arn]
  }
  # CloudWatch Logs
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
  # VPC networking
  statement {
    actions   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_transformer" {
  name   = "${var.project}-lambda-transformer-policy"
  role   = aws_iam_role.lambda_transformer.id
  policy = data.aws_iam_policy_document.lambda_transformer_policy.json
}

# ── Lambda Transformer: PII drop + schema whitelist + write Timestream ────────
data "archive_file" "transformer" {
  type        = "zip"
  output_path = "${path.module}/lambda_transformer.zip"
  source {
    content  = <<-PYTHON
import base64, json, boto3, os, re, logging
from datetime import datetime

logger    = logging.getLogger()
logger.setLevel(logging.INFO)
ts_client = boto3.client("timestream-write", region_name=os.environ["AWS_REGION"])
DB_NAME   = os.environ["TIMESTREAM_DB"]
TBL_NAME  = os.environ["TIMESTREAM_TABLE"]

# Schema whitelist - only these fields accepted (per Telemetry Contract)
ALLOWED_FIELDS = {"service_id", "tenant_id", "metric_type", "value", "timestamp", "unit"}

# PII patterns to redact
PII_PATTERNS = [
    (re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'), "[EMAIL_REDACTED]"),
    (re.compile(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'),             "[CARD_REDACTED]"),
    (re.compile(r'\b\d{10,12}\b'),                                         "[PHONE_REDACTED]"),
]

def redact_pii(value: str) -> str:
    for pattern, replacement in PII_PATTERNS:
        value = pattern.sub(replacement, value)
    return value

def handler(event, context):
    records_to_write = []

    for rec in event.get("Records", []):
        try:
            payload = json.loads(base64.b64decode(rec["kinesis"]["data"]).decode("utf-8"))

            # Schema whitelist check
            extra_fields = set(payload.keys()) - ALLOWED_FIELDS
            if extra_fields:
                logger.warning(f"Dropping extra fields: {extra_fields}")
                payload = {k: v for k, v in payload.items() if k in ALLOWED_FIELDS}

            # Validate required fields
            required = {"service_id", "tenant_id", "metric_type", "value"}
            if not required.issubset(payload.keys()):
                logger.error(f"Missing required fields, skipping record: {payload}")
                continue

            # PII redaction on string values
            for field in ["service_id", "tenant_id", "metric_type"]:
                if field in payload:
                    payload[field] = redact_pii(str(payload[field]))

            # Build Timestream record
            ts_ms = str(int(datetime.fromisoformat(
                payload.get("timestamp", datetime.utcnow().isoformat())
            ).timestamp() * 1000))

            records_to_write.append({
                "Dimensions": [
                    {"Name": "service_id",  "Value": payload["service_id"]},
                    {"Name": "tenant_id",   "Value": payload["tenant_id"]},
                    {"Name": "metric_type", "Value": payload["metric_type"]},
                ],
                "MeasureName":      "value",
                "MeasureValue":     str(float(payload["value"])),
                "MeasureValueType": "DOUBLE",
                "Time":             ts_ms,
                "TimeUnit":         "MILLISECONDS",
            })

        except Exception as e:
            logger.error(f"Error processing record: {e}")
            continue

    # Batch write to Timestream (max 100 records/call)
    if records_to_write:
        for i in range(0, len(records_to_write), 100):
            batch = records_to_write[i:i+100]
            try:
                ts_client.write_records(
                    DatabaseName=DB_NAME,
                    TableName=TBL_NAME,
                    Records=batch,
                    CommonAttributes={}
                )
                logger.info(f"Wrote {len(batch)} records to Timestream")
            except ts_client.exceptions.RejectedRecordsException as e:
                logger.error(f"Rejected records: {e.response['RejectedRecords']}")

    return {"statusCode": 200, "recordsProcessed": len(records_to_write)}
PYTHON
    filename = "lambda_transformer.py"
  }
}

resource "aws_cloudwatch_log_group" "lambda_transformer" {
  name              = "/aws/lambda/${var.project}-transformer"
  retention_in_days = 14
}

resource "aws_lambda_function" "transformer" {
  function_name    = "${var.project}-transformer"
  role             = aws_iam_role.lambda_transformer.arn
  runtime          = "python3.13"
  handler          = "lambda_transformer.handler"
  filename         = data.archive_file.transformer.output_path
  source_code_hash = data.archive_file.transformer.output_base64sha256
  timeout          = 60
  memory_size      = 256

  vpc_config {
    subnet_ids         = [var.private_app_subnet_id]
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      TIMESTREAM_DB    = var.timestream_database_name
      TIMESTREAM_TABLE = var.timestream_table_name
      AWS_ACCOUNT_ID   = data.aws_caller_identity.current.account_id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_transformer,
    aws_iam_role_policy.lambda_transformer,
  ]

  tags = { Name = "${var.project}-transformer" }
}

# Kinesis → Lambda trigger
resource "aws_lambda_event_source_mapping" "kinesis_to_transformer" {
  event_source_arn                   = aws_kinesis_stream.metrics.arn
  function_name                      = aws_lambda_function.transformer.arn
  starting_position                  = "LATEST"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  bisect_batch_on_function_error     = true # prevent 1 bad record blocking whole batch

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn
    }
  }
}

# ── DLQ cho Lambda Transformer ────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-transformer-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = { Name = "${var.project}-transformer-dlq" }
}

data "aws_caller_identity" "current" {}
