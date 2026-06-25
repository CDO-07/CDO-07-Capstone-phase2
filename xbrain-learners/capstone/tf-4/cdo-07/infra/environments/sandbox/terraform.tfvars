# Sandbox environment values - CDO-07 TF4
# DO NOT commit secrets here. Use AWS Secrets Manager or env vars for sensitive values.

aws_region  = "ap-southeast-1"
environment = "sandbox"
project     = "tf4-cdo07"

# Networking
vpc_cidr                 = "10.4.7.0/16"
public_subnet_cidr       = "10.4.7.0/24"
private_app_subnet_cidr  = "10.4.8.0/24"
private_data_subnet_cidr = "10.4.9.0/24"

# Kinesis - provisioned 2 shards (capstone scope)
kinesis_shard_count     = 2
kinesis_retention_hours = 24

# Timestream
timestream_memory_hours  = 48
timestream_magnetic_days = 90

# Budget circuit breaker
budget_limit_usd   = "200"
budget_alert_email = "REPLACE_WITH_TEAM_EMAIL@example.com"  # TODO: replace
