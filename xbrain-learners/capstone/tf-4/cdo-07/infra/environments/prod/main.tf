module "networking" {
  source = "../../modules/networking"

  vpc_name              = "cdo-07-prod-vpc"
  vpc_cidr              = "10.2.0.0/16"
  private_subnet_cidr_a = "10.2.1.0/24"
  private_subnet_cidr_b = "10.2.2.0/24"

  tags = {
    Environment = "Prod"
  }
}

module "mock_services" {
  source = "../../modules/ecs/mock-services"

  environment           = "prod"
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnets
  alb_security_group_id = module.networking.alb_security_group_id
  alb_http_listener_arn = module.networking.alb_http_listener_arn

  tags = {
    Environment = "Prod"
  }
}
