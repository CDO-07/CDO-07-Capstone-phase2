locals {
  aws_region  = "us-east-1"
  project     = "tf4-cdo07"
  environment = "prod"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "Terraform"
    Owner       = "CDO-07"
    TaskForce   = "TF4"
  }
}
