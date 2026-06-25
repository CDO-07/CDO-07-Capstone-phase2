# ─────────────────────────────────────────────────────────────────────────────
# Module: networking
# Creates: VPC, 3-tier subnets, IGW, NAT, Security Groups, VPC Endpoints
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# ── Subnets (3-tier) ──────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-subnet", Tier = "public" }
}

resource "aws_subnet" "private_app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = { Name = "${var.project}-private-app-subnet", Tier = "app" }
}

resource "aws_subnet" "private_data" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_data_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = { Name = "${var.project}-private-data-subnet", Tier = "data" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# ── NAT Gateway (cho private subnet outbound) ─────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project}-nat" }
  depends_on    = [aws_internet_gateway.main]
}

# ── Route Tables ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  subnet_id      = aws_subnet.private_data.id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────────────────────

# ALB SG: nhận HTTPS từ bên ngoài
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB: allow inbound 80/443 from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from k6/internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from k6/internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# App SG: ECS tasks (Mock Services + AI Engine)
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "ECS tasks: allow inbound from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From ALB on app port 8080"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound (VPC endpoints handle routing)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-app-sg" }
}

# Lambda SG: Lambda Transformer + Window Feeder + Fallback
resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda-sg"
  description = "Lambda functions: outbound to Timestream and Kinesis via VPC endpoints"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-lambda-sg" }
}

# ── VPC Endpoints (traffic không ra Internet) ─────────────────────────────────

# S3 Gateway endpoint (free, cho audit bucket + IaC state)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = { Name = "${var.project}-vpce-s3" }
}

# CloudWatch Logs Interface endpoint
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app.id]
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true
  tags                = { Name = "${var.project}-vpce-cwlogs" }
}

# Secrets Manager Interface endpoint
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app.id]
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true
  tags                = { Name = "${var.project}-vpce-sm" }
}

# Kinesis Streams Interface endpoint
resource "aws_vpc_endpoint" "kinesis" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.kinesis-streams"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app.id]
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true
  tags                = { Name = "${var.project}-vpce-kinesis" }
}

# SSM / Parameter Store Interface endpoint
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app.id]
  security_group_ids  = [aws_security_group.lambda.id]
  private_dns_enabled = true
  tags                = { Name = "${var.project}-vpce-ssm" }
}
