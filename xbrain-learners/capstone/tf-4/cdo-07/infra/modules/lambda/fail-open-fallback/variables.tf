###############################################################################
# Variables — Module: fail-open-fallback
###############################################################################

variable "project" {
  description = "Tiền tố project dùng để đặt tên tài nguyên AWS."
  type        = string
  default     = "tf4-cdo07"
}

variable "environment" {
  description = "Môi trường triển khai (sandbox | staging | prod)."
  type        = string
}

# ---------------------------------------------------------------------------
# Trigger
# ---------------------------------------------------------------------------
variable "window_feeder_failure_sns_arn" {
  description = "ARN của SNS topic mà Lambda Window Feeder publish khi thất bại. Lambda Fallback subscribe vào topic này để tự kích hoạt."
  type        = string
}

# ---------------------------------------------------------------------------
# Alert output
# ---------------------------------------------------------------------------
variable "alert_sns_topic_arn" {
  description = "ARN SNS topic để publish drift alert khi ngưỡng tĩnh bị vi phạm (thường là cùng topic với Window Feeder alerts → SNS → Slack)."
  type        = string
}

# ---------------------------------------------------------------------------
# Audit log (S3)
# ---------------------------------------------------------------------------
variable "audit_s3_bucket_name" {
  description = "Tên S3 bucket lưu audit log (không phải ARN — dùng trong s3.put_object)."
  type        = string
}

variable "audit_s3_bucket_arn" {
  description = "ARN S3 bucket audit log — dùng để scope IAM policy."
  type        = string
}

variable "audit_s3_prefix" {
  description = "Tiền tố key S3 cho audit log của Fallback Lambda (mặc định: fail-open-fallback/)."
  type        = string
  default     = "fail-open-fallback/"
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------
variable "kms_key_arn" {
  description = "ARN KMS CMK dùng để giải mã SSM SecureString (Grafana API key). Bắt buộc nếu grafana_api_key_parameter được set."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Grafana annotation (optional)
# ---------------------------------------------------------------------------
variable "grafana_host" {
  description = "Base URL của Amazon Managed Grafana workspace (ví dụ: https://g-xxxx.grafana-workspace.us-east-1.amazonaws.com). Để trống nếu không dùng."
  type        = string
  default     = ""
}

variable "grafana_api_key_parameter" {
  description = "Đường dẫn SSM Parameter Store chứa Grafana API key dạng SecureString (ví dụ: /tf4/cdo07/grafana-api-key). Để trống nếu không push annotation."
  type        = string
  default     = ""
}

variable "grafana_dashboard_uid" {
  description = "UID dashboard Grafana để gắn annotation. Để trống nếu muốn annotation hiển thị toàn bộ dashboard."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Static thresholds — có thể override per environment
# ---------------------------------------------------------------------------
variable "threshold_cpu_pct" {
  description = "Ngưỡng CPU utilization (%) để kích hoạt alert. Per ADR-001: 85%."
  type        = number
  default     = 85
  validation {
    condition     = var.threshold_cpu_pct > 0 && var.threshold_cpu_pct <= 100
    error_message = "threshold_cpu_pct phải trong khoảng (0, 100]."
  }
}

variable "threshold_memory_pct" {
  description = "Ngưỡng Memory utilization (%) để kích hoạt alert. Per ADR-001: 90%."
  type        = number
  default     = 90
  validation {
    condition     = var.threshold_memory_pct > 0 && var.threshold_memory_pct <= 100
    error_message = "threshold_memory_pct phải trong khoảng (0, 100]."
  }
}

variable "threshold_alb_connections" {
  description = "Ngưỡng số kết nối ALB đang hoạt động để kích hoạt alert. Per ADR-001: 450."
  type        = number
  default     = 450
  validation {
    condition     = var.threshold_alb_connections > 0
    error_message = "threshold_alb_connections phải > 0."
  }
}

variable "threshold_queue_depth" {
  description = "Ngưỡng độ sâu hàng đợi SQS để kích hoạt alert. Per ADR-001: 10000."
  type        = number
  default     = 10000
  validation {
    condition     = var.threshold_queue_depth > 0
    error_message = "threshold_queue_depth phải > 0."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
variable "log_level" {
  description = "Log level cho Lambda (DEBUG | INFO | WARNING | ERROR)."
  type        = string
  default     = "INFO"
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level phải là một trong: DEBUG, INFO, WARNING, ERROR."
  }
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------
variable "tags" {
  description = "Map tags áp dụng cho tất cả tài nguyên trong module."
  type        = map(string)
  default     = {}
}
