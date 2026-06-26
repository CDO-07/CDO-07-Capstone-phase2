# SNS to Slack Integration Module

This module sets up a secure, customizable pipeline that forwards Amazon Simple Notification Service (SNS) notifications to a Slack channel using an AWS Lambda function.

## Architecture

```
[ AWS Service (Alarm/Drift) ]
            │
            ▼
     [ SNS Topic ] ──(Trigger)──► [ Lambda Function ] ──(Retrieve)──► [ SSM Parameter Store (Slack Webhook) ]
                                          │
                                       (POST)
                                          ▼
                                   [ Slack Channel ]
```

## Security Best Practices
To conform to strict security guidelines, **never hardcode the Slack Webhook URL** in variables or environment variables in staging/production environments. 
1. Store the Slack Webhook URL as a `SecureString` parameter in **SSM Parameter Store** (e.g. `/tf4/cdo07/slack-webhook`).
2. Pass the parameter name to the module via `slack_webhook_parameter_name`.
3. If the parameter is encrypted with a custom KMS key, specify `kms_key_arn` to automatically grant the Lambda function decryption permissions.

*Note: A direct `slack_webhook_url` variable is available, but should **only** be used for short-lived sandbox environments.*

## Usage Example

```hcl
module "sns_to_slack" {
  source = "../modules/sns_to_slack"

  project     = "tf4-cdo07"
  environment = "staging"

  # Secure integration (SSM Parameter Store)
  slack_webhook_parameter_name = "/tf4/cdo07/slack-webhook"
  kms_key_arn                  = "arn:aws:kms:ap-southeast-1:123456789012:key/xxxx-xxxx-xxxx"
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| `project` | Project name prefix to tag and identify resources | `string` | `"tf4-cdo07"` | no |
| `environment` | Target deployment environment (e.g. `staging`, `prod`, `sandbox`) | `string` | n/a | yes |
| `sns_topic_name` | Custom name for the SNS topic. Defaults to `{project}-{environment}-slack-alerts` | `string` | `null` | no |
| `slack_webhook_parameter_name` | The name of the SSM Parameter containing the Slack Webhook URL | `string` | `null` | no |
| `slack_webhook_url` | Direct Slack Webhook URL (deprecated for production) | `string` | `null` | no |
| `kms_key_arn` | The KMS key ARN used to decrypt the SSM Parameter if using a Customer Managed Key | `string` | `null` | no |
| `lambda_function_name` | Custom name for the Lambda function. Defaults to `{project}-{environment}-sns-to-slack` | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| `sns_topic_arn` | The ARN of the generated SNS Topic |
| `sns_topic_name` | The name of the generated SNS Topic |
| `lambda_function_arn` | The ARN of the Lambda function forwarding alerts |
| `lambda_role_arn` | The ARN of the IAM Execution Role for the Lambda function |
