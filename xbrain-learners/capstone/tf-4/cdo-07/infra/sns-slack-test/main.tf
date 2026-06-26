terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
      Purpose     = "SNS-to-Slack-Testing"
    }
  }
}

# 1. Create the SSM Parameter Store resource securely holding the Slack Webhook
# checkov:skip=CKV_AWS_337: Using the default account KMS key (alias/aws/ssm) for decryption to simplify testing setup.
resource "aws_ssm_parameter" "slack_webhook" {
  name        = "/${var.project}/${var.environment}/slack-webhook"
  description = "SSM Secure Parameter for Slack Webhook integration tests"
  type        = "SecureString"
  value       = var.slack_webhook_url
}

# 2. Instantiate the reusable sns_to_slack module
module "sns_to_slack_test" {
  source = "../modules/sns_to_slack"

  project                      = var.project
  environment                  = var.environment
  slack_webhook_parameter_name = aws_ssm_parameter.slack_webhook.name
}
