# ─────────────────────────────────────────────────────────────────────────────
# Module: compute
# Creates: ECS Cluster, ALB, ECR repos, Task Definitions (Mock Services + AI Engine skeleton)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ── ECR Repositories ──────────────────────────────────────────────────────────

# AI Engine repo - AI team pushes their image here
resource "aws_ecr_repository" "ai_engine" {
  name                 = "${var.project}/ai-engine"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.project}-ai-engine-ecr" }
}

# Mock services repo
resource "aws_ecr_repository" "mock_services" {
  name                 = "${var.project}/mock-services"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  tags = { Name = "${var.project}-mock-services-ecr" }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── IAM Role cho ECS Tasks ────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Task Execution Role (pull image, push logs)
resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# AI Engine Task Role (Timestream query, SSM read, S3 audit write)
resource "aws_iam_role" "ai_engine_task" {
  name               = "${var.project}-ai-engine-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "ai_engine_task_policy" {
  # Timestream: query only (read baseline, query metrics)
  statement {
    actions   = ["timestream:Select", "timestream:DescribeEndpoints", "timestream:ListMeasures"]
    resources = ["*"]
  }
  # SSM: read inference_enabled flag
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"]
  }
  # S3: read baseline models
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.project}-baseline-models-*", "arn:aws:s3:::${var.project}-baseline-models-*/*"]
  }
  # CloudWatch: emit custom metrics
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ai_engine_task" {
  name   = "${var.project}-ai-engine-task-policy"
  role   = aws_iam_role.ai_engine_task.id
  policy = data.aws_iam_policy_document.ai_engine_task_policy.json
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ai_engine" {
  name              = "/ecs/${var.project}/ai-engine"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "mock_services" {
  name              = "/ecs/${var.project}/mock-services"
  retention_in_days = 7
}

# ── ECS Task Definition: AI Engine (skeleton) ─────────────────────────────────
resource "aws_ecs_task_definition" "ai_engine" {
  family                   = "${var.project}-ai-engine"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"  # 0.25 vCPU
  memory                   = "512"  # 512 MB per diagram
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ai_engine_task.arn

  container_definitions = jsonencode([{
    name      = "ai-engine"
    image     = var.ai_engine_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "PORT",              value = "8080" },
      { name = "TIMESTREAM_DB",     value = var.timestream_db_name },
      { name = "TIMESTREAM_TABLE",  value = var.timestream_tbl_name },
      { name = "AWS_REGION",        value = var.aws_region },
      { name = "SSM_INFERENCE_KEY", value = var.ssm_inference_param },
      # Skeleton response flag - AI team replaces with real logic
      { name = "SKELETON_MODE",     value = "true" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ai_engine.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ai-engine"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])

  tags = { Name = "${var.project}-ai-engine-task" }
}

# ── ECS Task Definition: Mock Services (3 services) ──────────────────────────
resource "aws_ecs_task_definition" "mock_services" {
  family                   = "${var.project}-mock-services"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "payment-gateway"
      image     = var.mock_service_image
      essential = true
      command   = ["node", "-e", "require('http').createServer((req,res)=>{res.end(JSON.stringify({service:'payment-gateway',status:'ok'}))}).listen(8081)"]
      portMappings = [{ containerPort = 8081, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mock_services.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "payment-gateway"
        }
      }
    },
    {
      name      = "kyc-service"
      image     = var.mock_service_image
      essential = false
      command   = ["node", "-e", "require('http').createServer((req,res)=>{res.end(JSON.stringify({service:'kyc-service',status:'ok'}))}).listen(8082)"]
      portMappings = [{ containerPort = 8082, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mock_services.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "kyc-service"
        }
      }
    },
    {
      name      = "reporting-svc"
      image     = var.mock_service_image
      essential = false
      command   = ["node", "-e", "require('http').createServer((req,res)=>{res.end(JSON.stringify({service:'reporting-svc',status:'ok'}))}).listen(8083)"]
      portMappings = [{ containerPort = 8083, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mock_services.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "reporting-svc"
        }
      }
    }
  ])

  tags = { Name = "${var.project}-mock-services-task" }
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = [var.public_subnet_id]

  tags = { Name = "${var.project}-alb" }
}

# Target group: AI Engine /v1/predict
resource "aws_lb_target_group" "ai_engine" {
  name        = "${var.project}-ai-engine-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.project}-ai-engine-tg" }
}

# Target group: Ingest Service /v1/telemetry (mock - routes to mock services)
resource "aws_lb_target_group" "ingest" {
  name        = "${var.project}-ingest-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.project}-ingest-tg" }
}

# ALB Listener HTTP:80 with path-based routing
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Default: 404
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "predict" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_engine.arn
  }

  condition {
    path_pattern { values = ["/v1/predict", "/v1/predict/*"] }
  }
}

resource "aws_lb_listener_rule" "telemetry" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingest.arn
  }

  condition {
    path_pattern { values = ["/v1/telemetry", "/v1/telemetry/*"] }
  }
}

# ── ECS Services ──────────────────────────────────────────────────────────────
resource "aws_ecs_service" "ai_engine" {
  name            = "${var.project}-ai-engine"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.ai_engine.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [var.private_app_subnet_id]
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ai_engine.arn
    container_name   = "ai-engine"
    container_port   = 8080
  }

  # Allow AI team to deploy without Terraform (they update task def via CI/CD)
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = { Name = "${var.project}-ai-engine-service" }
}
