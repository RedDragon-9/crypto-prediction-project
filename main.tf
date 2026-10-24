terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket = "crypto-prediction-tfstate-017562255734"
    key    = "production/ecs-express/terraform.tfstate"
    region = "eu-north-1"
  }
}

provider "aws" {
  region = "eu-north-1"
}

# =================================================================
# 0. DEVOPS INPUT PARAMETERS (ANONYMOUS & PORTABLE VARIABLES)
# =================================================================

variable "root_domain_name" {
  type        = string
  description = "The raw root domain name hosted inside your Route 53 account (e.g., example.com)"
}

variable "app_subdomain_name" {
  type        = string
  description = "The full custom address where the app will be accessed (e.g., example.com)"
}

# =================================================================
# 1. SECURITY & PASSWORD ORCHESTRATION
# =================================================================

resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# =================================================================
# 2. NETWORK PROVISIONING (VPC & PRIVATE SUBNETS)
# =================================================================

resource "aws_vpc" "app_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "crypto-production-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-north-1b"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "eu-north-1a"
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "eu-north-1b"
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "pub_assoc_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "pub_assoc_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "crypto-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

# =================================================================
# 3. FIREWALL SECURITY POLICIES (SECURITY GROUPS)
# =================================================================

# Load Balancer Firewall: Accepts public traffic on HTTP (80) and HTTPS (443)
resource "aws_security_group" "alb_sg" {
  name   = "crypto-alb-sg"
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
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
}

# ECS Tasks Firewall: Only accepts traffic routed from the ALB to your Flask application port
resource "aws_security_group" "ecs_tasks_sg" {
  name   = "crypto-ecs-tasks-sg"
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Database Firewall: ONLY allows traffic traveling internally from the ECS compute tier
resource "aws_security_group" "db_sg" {
  name   = "crypto-private-db-sg"
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =================================================================
# 4. PRIVATELY HIDDEN DATABASE LAYER (AWS RDS)
# =================================================================

resource "aws_db_instance" "mysql_db" {
  identifier             = "crypto-production-db"
  allocated_storage      = 20
  max_allocated_storage  = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "bitcoin"
  username               = "db_master_admin"
  password               = random_password.db_password.result
  parameter_group_name   = "default.mysql8.0"
  skip_final_snapshot    = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
}

# =================================================================
# 5. CONTAINER REGISTRY PROVISIONING & STORAGE CONTROL (AWS ECR)
# =================================================================

resource "aws_ecr_repository" "app_ecr" {
  name                 = "crypto-prediction-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "ecr_cleanup_policy" {
  repository = aws_ecr_repository.app_ecr.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain only the single latest container layer version to preserve credit allocation space"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# =================================================================
# 6. APPLICATION COMPUTE PROVISIONING (AMAZON ECS FARGATE)
# =================================================================

resource "aws_ecs_cluster" "main" {
  name = "crypto-production-cluster"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "crypto-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/crypto-prediction-app"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "app" {
  family                   = "crypto-prediction-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "flask-app"
    image     = "${aws_ecr_repository.app_ecr.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 5000
      hostPort      = 5000
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = "eu-north-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
    environment = [
      { name = "DB_HOST", value = aws_db_instance.mysql_db.address },
      { name = "DB_USER", value = "db_master_admin" },
      { name = "DB_PASSWORD", value = random_password.db_password.result },
      { name = "DB_NAME", value = "bitcoin" }
    ]
  }])
}

# =================================================================
# 6b. NETWORKING LOAD BALANCER LAYER (ALB)
# =================================================================

resource "aws_alb" "main" {
  name            = "crypto-app-alb"
  subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  security_groups = [aws_security_group.alb_sg.id]
}

resource "aws_alb_target_group" "app" {
  name        = "crypto-app-target-group"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.app_vpc.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

# HTTP Listener - Automated 301 Permanent Redirect to safe HTTPS
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener - Handles secure 443 handshake using verified ACM SSL cert
resource "aws_alb_listener" "https" {
  load_balancer_arn = aws_alb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.app_cert_verify.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.app.arn
  }
}

# =================================================================
# 6c. RUNNING LIVE ECS SERVICE
# =================================================================

resource "aws_ecs_service" "main" {
  name            = "crypto-prediction-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks_sg.id]
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.arn
    container_name   = "flask-app"
    container_port   = 5000
  }

  depends_on = [aws_alb_listener.https, aws_db_instance.mysql_db]
}

# =================================================================
# 7. ROUTE 53 AUTOMATION & SSL CERTIFICATE PROVISIONING
# =================================================================

data "aws_route53_zone" "primary" {
  name         = "${var.root_domain_name}."
  private_zone = false
}

# Request a free SSL certificate from AWS Certificate Manager
resource "aws_acm_certificate" "app_cert" {
  domain_name       = var.app_subdomain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Generate DNS validation handshake records in Route 53
resource "aws_route53_record" "cert_validation" {
  count = 1

  allow_overwrite = true
  name            = tolist(aws_acm_certificate.app_cert.domain_validation_options)[0].resource_record_name
  records         = [tolist(aws_acm_certificate.app_cert.domain_validation_options)[0].resource_record_value]
  ttl             = 60
  type            = tolist(aws_acm_certificate.app_cert.domain_validation_options)[0].resource_record_type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

# Explicitly wait until AWS confirms the SSL certificate is fully validated and active
resource "aws_acm_certificate_validation" "app_cert_verify" {
  certificate_arn         = aws_acm_certificate.app_cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]
}

# Custom Traffic Routing Alias Record: Connects your subdomain directly to the public ALB
resource "aws_route53_record" "app_alias" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.app_subdomain_name
  type    = "A"

  alias {
    name                   = aws_alb.main.dns_name
    zone_id                = aws_alb.main.zone_id
    evaluate_target_health = true
  }
}

# =================================================================
# 8. MANAGEMENT DATA OUTPUT CONTROLS
# =================================================================

output "alb_dns_name" {
  value       = aws_alb.main.dns_name
  description = "The public DNS endpoint URL of the Application Load Balancer"
}

output "custom_domain_url" {
  value       = "https://${var.app_subdomain_name}"
  description = "Your live web application access custom domain endpoint link address"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.app_ecr.repository_url
  description = "The target ECR repository URL endpoint for image tagging steps"
}
