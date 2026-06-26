module "cost_circuit_breaker" {
  source = "../../modules/cost-circuit-breaker"

  project                   = local.project
  environment               = local.environment
  aws_region                = local.aws_region
  monthly_budget_limit_usd  = 200
  warning_threshold_percent = 80
  hard_threshold_percent    = 100
  ssm_parameter_name        = "/${local.project}/${local.environment}/inference_enabled"
  warning_email_addresses   = []
  lambda_timeout_seconds    = 10
  log_retention_days        = 30
  tags                      = local.common_tags
}
