###############################################################################
# Root variables — CDO-07 · Task Force 4
# Khai báo các input variable cho infra/main.tf
###############################################################################

# ---------------------------------------------------------------------------
# Fail-Open Fallback — Trigger
# ---------------------------------------------------------------------------
variable "window_feeder_failure_sns_arn" {
  description = "ARN SNS topic mà Lambda Window Feeder publish khi thất bại. Fallback Lambda subscribe vào đây."
  type        = string
}

# ---------------------------------------------------------------------------
# Fail-Open Fallback — Alert output
# ---------------------------------------------------------------------------
variable "alert_sns_topic_arn" {
  description = "ARN SNS topic để Fallback Lambda publish drift alert (thường là topic chung → Slack)."
  type        = string
}

# ---------------------------------------------------------------------------
# Fail-Open Fallback — Audit log S3
# ---------------------------------------------------------------------------
variable "audit_s3_bucket_name" {
  description = "Tên S3 bucket lưu audit log của Fallback Lambda."
  type        = string
}

variable "audit_s3_bucket_arn" {
  description = "ARN S3 bucket audit log — dùng để scope IAM policy."
  type        = string
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------
variable "kms_key_arn" {
  description = "ARN KMS CMK để decrypt SSM SecureString (Grafana API key). Lấy từ bootstrap output."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Grafana annotation (optional)
# ---------------------------------------------------------------------------
variable "grafana_host" {
  description = "Base URL Managed Grafana workspace. Để trống nếu chưa có."
  type        = string
  default     = ""
}

variable "grafana_api_key_parameter" {
  description = "Path SSM Parameter Store chứa Grafana API key (SecureString). Để trống nếu không push annotation."
  type        = string
  default     = ""
}

variable "grafana_dashboard_uid" {
  description = "UID dashboard Grafana để gắn annotation. Để trống nếu muốn annotation toàn bộ."
  type        = string
  default     = ""
}
