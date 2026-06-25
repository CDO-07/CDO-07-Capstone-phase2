# ─────────────────────────────────────────────────────────────────────────────
# TF4 Foresight Lens — CDO-07 Platform Infrastructure
# Region: ap-southeast-1
# Architecture: Event-driven hybrid (Kinesis → Timestream → AI Engine → Grafana)
# ─────────────────────────────────────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"

  project                  = var.project
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  public_subnet_cidr       = var.public_subnet_cidr
  private_app_subnet_cidr  = var.private_app_subnet_cidr
  private_data_subnet_cidr = var.private_data_subnet_cidr
  aws_region               = var.aws_region
}

module "compute" {
  source = "./modules/compute"

  project             = var.project
  environment         = var.environment
  aws_region          = var.aws_region
  vpc_id              = module.networking.vpc_id
  public_subnet_id    = module.networking.public_subnet_id
  private_app_subnet_id = module.networking.private_app_subnet_id
  alb_sg_id           = module.networking.alb_sg_id
  app_sg_id           = module.networking.app_sg_id
  mock_service_image  = var.mock_service_image
  ai_engine_image     = var.ai_engine_image
  timestream_db_name  = module.storage.timestream_database_name
  timestream_tbl_name = module.storage.timestream_table_name
  kinesis_stream_arn  = module.ingest.kinesis_stream_arn
  ssm_inference_param = module.storage.ssm_inference_param_name
}

module "storage" {
  source = "./modules/storage"

  project                  = var.project
  environment              = var.environment
  aws_region               = var.aws_region
  timestream_memory_hours  = var.timestream_memory_hours
  timestream_magnetic_days = var.timestream_magnetic_days
}

module "ingest" {
  source = "./modules/ingest"

  project                  = var.project
  environment              = var.environment
  aws_region               = var.aws_region
  kinesis_shard_count      = var.kinesis_shard_count
  kinesis_retention_hours  = var.kinesis_retention_hours
  private_app_subnet_id    = module.networking.private_app_subnet_id
  lambda_sg_id             = module.networking.lambda_sg_id
  timestream_database_name = module.storage.timestream_database_name
  timestream_table_name    = module.storage.timestream_table_name
  timestream_table_arn     = module.storage.timestream_table_arn
  audit_bucket_name        = module.storage.audit_bucket_name
}

module "observability" {
  source = "./modules/observability"

  project            = var.project
  environment        = var.environment
  aws_region         = var.aws_region
  budget_limit_usd   = var.budget_limit_usd
  budget_alert_email = var.budget_alert_email
  ecs_cluster_name   = module.compute.ecs_cluster_name
  kinesis_stream_name = module.ingest.kinesis_stream_name
  alb_arn_suffix     = module.compute.alb_arn_suffix
}
