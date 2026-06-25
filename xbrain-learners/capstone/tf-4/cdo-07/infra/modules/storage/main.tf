# ─────────────────────────────────────────────────────────────────────────────
# Module: storage
# Creates: Timestream DB/table, S3 audit bucket (Object Lock), S3 baseline models, SSM params
# ─────────────────────────────────────────────────────────────────────────────

# ── KMS key cho audit log ─────────────────────────────────────────────────────
resource "aws_kms_key" "audit" {
  description             = "${var.project} audit log CMK"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${var.project}-audit-cmk" }
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.project}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

# ── Amazon Timestream ─────────────────────────────────────────────────────────
resource "aws_timestreamwrite_database" "main" {
  database_name = "${var.project}-metrics"
  tags          = { Name = "${var.project}-timestream-db" }
}

resource "aws_timestreamwrite_table" "metrics" {
  database_name = aws_timestreamwrite_database.main.database_name
  table_name    = "service-metrics"

  retention_properties {
    memory_store_retention_period_in_hours  = var.timestream_memory_hours
    magnetic_store_retention_period_in_days = var.timestream_magnetic_days
  }

  # Magnetic store write enabled for late-arriving data
  magnetic_store_write_properties {
    enable_magnetic_store_writes = true
  }

  tags = { Name = "${var.project}-metrics-table" }
}

# ── S3: Audit Log bucket (Object Lock - tamper-evident) ───────────────────────
resource "aws_s3_bucket" "audit" {
  bucket        = "${var.project}-audit-log-${var.environment}"
  force_destroy = false # NEVER force delete audit bucket

  tags = { Name = "${var.project}-audit-log", Purpose = "audit" }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE" # GOVERNANCE cho sandbox (admin có thể override)
      days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── S3: Baseline Models bucket (AI team reads baseline từ đây) ────────────────
resource "aws_s3_bucket" "baseline" {
  bucket = "${var.project}-baseline-models-${var.environment}"
  tags   = { Name = "${var.project}-baseline-models", Purpose = "ml-baseline" }
}

resource "aws_s3_bucket_versioning" "baseline" {
  bucket = aws_s3_bucket.baseline.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "baseline" {
  bucket = aws_s3_bucket.baseline.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "baseline" {
  bucket                  = aws_s3_bucket.baseline.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── SSM Parameter Store ───────────────────────────────────────────────────────

# Flag: AI engine có đang enable không (dùng cho Fail-Open Fallback)
resource "aws_ssm_parameter" "inference_enabled" {
  name  = "/${var.project}/${var.environment}/inference_enabled"
  type  = "String"
  value = "true"
  tags  = { Name = "${var.project}-inference-enabled" }
}

# Timestream connection info cho AI engine
resource "aws_ssm_parameter" "timestream_db" {
  name  = "/${var.project}/${var.environment}/timestream_database"
  type  = "String"
  value = aws_timestreamwrite_database.main.database_name
}

resource "aws_ssm_parameter" "timestream_table" {
  name  = "/${var.project}/${var.environment}/timestream_table"
  type  = "String"
  value = aws_timestreamwrite_table.metrics.table_name
}
