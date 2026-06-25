terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  backend "s3" {
    bucket         = "tf4-cdo07-tf-state"
    key            = "sandbox/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "tf4-cdo07-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "tf4-foresight-lens"
      Team        = "cdo-07"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
