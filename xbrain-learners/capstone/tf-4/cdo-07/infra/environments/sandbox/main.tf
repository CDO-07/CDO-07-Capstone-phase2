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

module "networking" {
  source = "../../modules/networking"

  vpc_name              = "cdo-07-sandbox-vpc"
  vpc_cidr              = "10.0.0.0/16"
  private_subnet_cidr_a = "10.0.1.0/24"
  private_subnet_cidr_b = "10.0.2.0/24"

  tags = {
    Environment = "Sandbox"
  }
}

module "mock_services" {
  source = "../../modules/ecs/mock-services"

  environment           = "sandbox"
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnets
  alb_security_group_id = module.networking.alb_security_group_id
  alb_http_listener_arn = module.networking.alb_http_listener_arn

  tags = {
    Environment = "Sandbox"
  }
}
