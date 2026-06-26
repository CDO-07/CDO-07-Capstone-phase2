module "networking" {
  source = "../../modules/networking"

  vpc_name              = "cdo-07-staging-vpc"
  vpc_cidr              = "10.1.0.0/16"
  private_subnet_cidr_a = "10.1.1.0/24"
  private_subnet_cidr_b = "10.1.2.0/24"

  tags = {
    Environment = "Staging"
  }
}

module "mock_services" {
  source = "../../modules/ecs/mock-services"

  environment           = "staging"
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnets
  alb_security_group_id = module.networking.alb_security_group_id
  alb_http_listener_arn = module.networking.alb_http_listener_arn

  tags = {
    Environment = "Staging"
  }
}
