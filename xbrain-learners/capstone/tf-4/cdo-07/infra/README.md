# CDO-07 Infrastructure - TF4 Foresight Lens

Terraform IaC cho platform CDO-07. Region: `ap-southeast-1`.

## Cấu trúc

```
infra/
├── main.tf              # Root: gọi 5 modules
├── variables.tf         # Input variables
├── outputs.tf           # Output values (ALB URL, Timestream endpoint...)
├── versions.tf          # Terraform + provider version pin
├── modules/
│   ├── networking/      # VPC, 3-tier subnet, SG, VPC Endpoints
│   ├── compute/         # ECS Cluster, ALB, ECR, Task Definitions
│   ├── storage/         # Timestream, S3 audit + baseline, SSM params
│   ├── ingest/          # Kinesis Data Stream, Lambda Transformer, DLQ
│   └── observability/   # CloudWatch Alarms, AWS Budgets, Cost CB Lambda
├── environments/
│   └── sandbox/
│       └── terraform.tfvars
└── scripts/
    └── bootstrap.sh     # Run ONCE: tạo S3 state + DynamoDB lock
```

## Lần đầu setup (chạy 1 lần)

```bash
# 1. Configure AWS credentials
aws configure  # hoặc export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

# 2. Bootstrap state backend
bash scripts/bootstrap.sh

# 3. Init Terraform
cd infra
terraform init

# 4. Plan
terraform plan -var-file=environments/sandbox/terraform.tfvars

# 5. Apply
terraform apply -var-file=environments/sandbox/terraform.tfvars
```

## Sau khi apply xong

Terraform output sẽ in ra:

```
alb_dns_name           = "tf4-cdo07-alb-xxxx.ap-southeast-1.elb.amazonaws.com"
alb_predict_url        = "http://<alb>/v1/predict"
alb_telemetry_url      = "http://<alb>/v1/telemetry"
ecr_ai_engine_repo_url = "<account>.dkr.ecr.ap-southeast-1.amazonaws.com/tf4-cdo07/ai-engine"
timestream_database_name = "tf4-cdo07-metrics"
timestream_table_name    = "service-metrics"
kinesis_stream_name      = "tf4-cdo07-metrics-stream"
```

**Gửi cho AI team:**
- `alb_predict_url` → AI team deploy skeleton endpoint tại đây
- `ecr_ai_engine_repo_url` → AI team push image lên đây
- `timestream_database_name` + `timestream_table_name` → AI team query metrics

## Gửi metric test vào Kinesis

```bash
# Test 1 record
aws kinesis put-record \
  --stream-name tf4-cdo07-metrics-stream \
  --partition-key "payment-gateway" \
  --data '{"service_id":"payment-gateway","tenant_id":"tf4-demo","metric_type":"cpu_percent","value":45.2,"timestamp":"2026-06-23T10:00:00Z","unit":"percent"}' \
  --region ap-southeast-1
```

## Destroy (dọn dẹp sau capstone)

```bash
terraform destroy -var-file=environments/sandbox/terraform.tfvars
# Sau đó xóa state bucket thủ công (Object Lock bucket KHÔNG tự xóa được)
```

## TODO W12

- [ ] EventBridge + Lambda Window Feeder (gọi AI predict mỗi 5 phút)
- [ ] Lambda Fail-Open Fallback
- [ ] Managed Grafana workspace + Timestream datasource
- [ ] SNS → Slack webhook integration
- [ ] CI/CD GitHub Actions pipeline
