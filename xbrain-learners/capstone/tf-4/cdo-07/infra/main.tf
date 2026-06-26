###############################################################################
# Root module — CDO-07 · Task Force 4 · Foresight Lens
# File này chỉ chứa các module do CDO-07 tự build.
# Không chứa module networking/ecs/mock-services (thuộc environments/).
###############################################################################

# ---------------------------------------------------------------------------
# [Resilience] Fail-Open Fallback Lambda
# Trigger: SNS từ Window Feeder khi timeout hoặc AI Engine down
# Nhiệm vụ: đánh giá ngưỡng tĩnh, publish SNS alert, push Grafana annotation,
#           ghi audit log S3
# ---------------------------------------------------------------------------
module "fail_open_fallback" {
  source = "./modules/lambda/fail-open-fallback"

  project     = "tf4-cdo07"
  environment = "capstone"

  # --- Trigger: Window Feeder publish vào topic này khi bị lỗi ---
  # Thay bằng ARN thực sau khi Window Feeder module được deploy
  window_feeder_failure_sns_arn = var.window_feeder_failure_sns_arn

  # --- Output: topic để publish drift alert → SNS → Slack ---
  alert_sns_topic_arn = var.alert_sns_topic_arn

  # --- Audit log S3 ---
  audit_s3_bucket_name = var.audit_s3_bucket_name
  audit_s3_bucket_arn  = var.audit_s3_bucket_arn
  audit_s3_prefix      = "fail-open-fallback/"

  # --- KMS key để decrypt SSM SecureString ---
  kms_key_arn = var.kms_key_arn

  # --- Grafana annotation (optional — để trống nếu chưa có workspace) ---
  grafana_host              = var.grafana_host
  grafana_api_key_parameter = var.grafana_api_key_parameter
  grafana_dashboard_uid     = var.grafana_dashboard_uid

  # --- Ngưỡng tĩnh per ADR-001 ---
  threshold_cpu_pct         = 85
  threshold_memory_pct      = 90
  threshold_alb_connections = 450
  threshold_queue_depth     = 10000

  tags = {
    Team      = "CDO-07"
    TaskForce = "TF4"
    Component = "fail-open-fallback"
    ManagedBy = "Terraform"
  }
}
