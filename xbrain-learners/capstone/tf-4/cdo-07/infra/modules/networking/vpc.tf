data "aws_availability_zones" "available" {}

locals {
  name = var.vpc_name
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = var.vpc_cidr

  # AWS ALB requires at least 2 AZs. We add a second AZ/Subnet to fulfill this requirement.
  azs             = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  private_subnets = [var.private_subnet_cidr_a, var.private_subnet_cidr_b]

  # No public subnets based on strict requirements, assuming internal ALB.
  # If ALB needs to be internet-facing, public subnets and IGW would be required.
  create_igw         = false
  enable_nat_gateway = false

  tags = var.tags
}
