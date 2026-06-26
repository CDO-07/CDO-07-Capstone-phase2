provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "Sandbox"
      Team        = "CDO-07"
      Project     = "Foresight Lens"
      ManagedBy   = "Terraform"
    }
  }
}

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {} # State backend configuration would go here
}
