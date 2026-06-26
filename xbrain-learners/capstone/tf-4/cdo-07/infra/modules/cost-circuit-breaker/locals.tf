locals {
  name_prefix        = "${var.project}-${var.environment}"
  lambda_name        = "${local.name_prefix}-cost-circuit-breaker"
  ssm_parameter_path = trimprefix(var.ssm_parameter_name, "/")

  common_tags = merge(var.tags, {
    Component = "cost-circuit-breaker"
  })
}
