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
  description = "The full custom address where the app will be accessed (e.g., ://example.com)"
}

# =================================================================
# 1. SECURITY & PASSSWORD ORCHESTRATION
# =================================================================

# Dynamically generate a high-entropy password for the private database layer
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# =================================================================
# 2. NETWORK PROVISIONING (VPC & PRIVATE SUBNETS)
# =================================================================

# Create a dedicated, completely isolated Virtual Private Cloud network
resource "aws_vpc" "app_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "crypto-production-vpc" }
}

# Create Private Subnet A for the database engine cluster
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-north-1a" # Assigned to Sweden Zone A
}

# Create Private Subnet B (AWS RDS requires at least 2 subnets across different zones)
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-north-1b" # Assigned to Sweden Zone B
}

# Bind the subnets together into a deployment group for the database cluster
resource "aws_db_subnet_group" "db_subnets" {
  name       = "crypto-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

# =================================================================
# 3. FIREWALL SECURITY POLICIES (SECURITY GROUPS)
# =================================================================

# Database Firewall: ONLY allows traffic traveling internally from within the VPC network
resource "aws_security_group" "db_sg" {
  name   = "crypto-private-db-sg"
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Restricted strictly to your internal VPC traffic
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# App Connector Firewall: Allows the App Runner web container to bridge cleanly into your VPC
resource "aws_security_group" "app_connector_sg" {
  name   = "crypto-app-connector-sg"
  vpc_id = aws_vpc.app_vpc.id

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

# Provision the Managed Free-Tier MySQL Database Engine
resource "aws_db_instance" "mysql_db" {
  identifier             = "crypto-production-db"
  allocated_storage      = 20
  max_allocated_storage  = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro" # AWS Free-Tier eligible
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

# Create a private registry to store your security-hardened Docker images
resource "aws_ecr_repository" "app_ecr" {
  name                 = "crypto-prediction-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# COST OPTIMIZATION CONTROL: Enforces a policy that keeps only 1 active image version.
# Automatically purges old builds to ensure new accounts remain inside Free Tier space limits.
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
# 6. APPLICATION COMPUTE PROVISIONING (AWS APP RUNNER)
# =================================================================

# Create the IAM Role that allows App Runner to read images from your ECR repo
resource "aws_iam_role" "apprunner_ecr_role" {
  name = "apprunner-ecr-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "://amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr_policy" {
  role       = aws_iam_role.apprunner_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Private Network Bridge: Establishes a communication connector tunnel into the private subnet VPC
resource "aws_apprunner_vpc_connector" "vpc_connector" {
  vpc_connector_name = "crypto-app-vpc-connector"
  subnets            = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_groups    = [aws_security_group.app_connector_sg.id]
}

# Provision the live public web server service on AWS App Runner
resource "aws_apprunner_service" "flask_app" {
  service_name = "crypto-prediction-service"
  
  source_configuration {
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_ecr_role.arn
    }
    
    image_repository {
      image_identifier      = "${aws_ecr_repository.app_ecr.repository_url}:latest"
      image_repository_type = "ECR"
      
      image_configuration {
        port = "5000" # Exposes your Flask application port map
        runtime_environment_variables = {
          DB_HOST     = aws_db_instance.mysql_db.address
          DB_USER     = "db_master_admin"
          DB_PASSWORD = random_password.db_password.result
          DB_NAME     = "bitcoin"
        }
      }
    }
    auto_deployments_enabled = true
  }

  # Link the application container directly into the private network tunnel
  network_configuration {
    egress_configuration {
      egress_type       = "VPC"
      vpc_connector_arn = aws_apprunner_vpc_connector.vpc_connector.arn
    }
  }

  depends_on = [
    aws_db_instance.mysql_db,
    aws_ecr_repository.app_ecr,
    aws_apprunner_vpc_connector.vpc_connector
  ]
}

# =================================================================
# 7. ROUTE 53 AUTOMATION & CUSTOM DOMAIN PROVISIONING
# =================================================================

# Pulls your primary pre-existing Route 53 zone records map setup context safely using input variables
data "aws_route53_zone" "primary" {
  name         = "${var.root_domain_name}." # Dynamically appends the trailing dot safely
  private_zone = false
}

# Links your custom subdomain target down into the active AWS App Runner instance
resource "aws_apprunner_custom_domain_association" "app_domain" {
  service_arn          = aws_apprunner_service.flask_app.service_arn
  domain_name          = var.app_subdomain_name # Securely generalized input
  enable_www_subdomain = false
}

# Loop Automation: Writes out CNAME security validation records into Route 53 automatically for SSL activation
resource "aws_route53_record" "apprunner_validation" {
  for_each = {
    for record in aws_apprunner_custom_domain_association.app_domain.certificate_validation_records : record.name => record
  }

  zone_id = data.aws_route53_zone.primary.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.value]
}

# Final Traffic Routing Alias Record: Connects your subdomain target to the App Runner runtime proxy gateway
resource "aws_route53_record" "app_alias" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.app_subdomain_name # Securely generalized input
  type    = "CNAME"
  ttl     = 300
  records = [aws_apprunner_custom_domain_association.app_domain.dns_target]
}

# =================================================================
# 8. MANAGEMENT DATA OUTPUT CONTROLS
# =================================================================

output "app_url" {
  value       = aws_apprunner_service.flask_app.service_url
  description = "The direct internal AWS HTTPS URL gateway provided to access your web framework"
}

output "custom_domain_url" {
value       = "https://${aws_apprunner_custom_domain_association.app_domain.domain_name}"
description = "Your live web application access custom domain endpoint link address"
}
output "ecr_repository_url" {
value       = aws_ecr_repository.app_ecr.repository_url
description = "The target ECR repository URL endpoint for image tagging steps"
}
