################################################################################
# Alchemyst AI - DevOps Internship Assignment
# Distributed Inference System on AWS
# Single-file Terraform - copy this entire file as main.tf
################################################################################

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################################################################################
# PROVIDER
################################################################################

provider "aws" {
  region = var.aws_region
}

################################################################################
# VARIABLES - Edit these before running terraform apply
################################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "your_ip" {
  description = "Your public IP for SSH access e.g. 102.89.12.34/32 (run: curl ifconfig.me)"
  type        = string
}

variable "key_pair_name" {
  description = "Name of your AWS EC2 key pair"
  type        = string
}

variable "project_name" {
  description = "Project name used for tagging"
  type        = string
  default     = "alchemyst-inference"
}

################################################################################
# LOCALS
################################################################################

locals {
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
  availability_zone   = "${var.aws_region}a"
  ami_id              = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS us-east-1
}

################################################################################
# NETWORKING - VPC, Subnets, IGW, NAT Gateway, Route Tables
################################################################################

# VPC
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# Public Subnet (10.0.1.0/24)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# Private Subnet (10.0.2.0/24)
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.private_subnet_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name    = "${var.project_name}-private-subnet"
    Project = var.project_name
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-nat-eip"
    Project = var.project_name
  }
}

# NAT Gateway (in public subnet - allows private VM to reach internet)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]

  tags = {
    Name    = "${var.project_name}-nat-gateway"
    Project = var.project_name
  }
}

# Public Route Table - Route: 0.0.0.0/0 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table - Route: 0.0.0.0/0 → NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name    = "${var.project_name}-private-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

################################################################################
# SECURITY GROUPS
################################################################################

# Bastion Host SG - SSH from your IP only
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "Bastion host - SSH from your IP only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from your IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-bastion-sg"
    Project = var.project_name
  }
}

# API Gateway SG - HTTP :3111 from internet, WebSocket :49134 in VPC, SSH from bastion
resource "aws_security_group" "api_gateway" {
  name        = "${var.project_name}-api-gateway-sg"
  description = "API Gateway - HTTP inference endpoint"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Inference HTTP API from internet"
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "iii engine WebSocket within VPC"
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-api-gateway-sg"
    Project = var.project_name
  }
}

# Inference Worker SG - WebSocket :49134 from API GW only, SSH from bastion only
resource "aws_security_group" "inference" {
  name        = "${var.project_name}-inference-sg"
  description = "Inference worker - private, RPC from API GW only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "iii engine WebSocket from API Gateway only"
    from_port       = 49134
    to_port         = 49134
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id]
  }

  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Outbound via NAT Gateway to download model"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-inference-sg"
    Project = var.project_name
  }
}

################################################################################
# COMPUTE - 3 EC2 VMs
################################################################################

# VM 1: Bastion Host (Public Subnet)
resource "aws_instance" "bastion" {
  ami                         = local.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y curl wget git
    echo "Bastion host ready" > /home/ubuntu/ready.txt
  EOF

  tags = {
    Name    = "${var.project_name}-bastion"
    Role    = "bastion"
    Project = var.project_name
  }
}

# VM 2: API Gateway (Public Subnet)
# Runs: iii engine + caller-worker (TypeScript) + HTTP :3111      
resource "aws_instance" "api_gateway" {
  ami           = local.ami_id
  instance_type = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.api_gateway.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y curl wget git unzip

    # Install Node.js 20
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs

    # Install iii CLI
    npm install -g iii

    # Clone the quickstart project
    cd /home/ubuntu
    git clone https://github.com/Alchemyst-ai/hiring.git
    cd hiring/may-2026/devops/quickstart

    # Init the iii project
    iii project init quickstart --template quickstart
    cd quickstart

    # Systemd: iii engine
    cat > /etc/systemd/system/iii-engine.service <<SERVICE
[Unit]
Description=iii Engine
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/hiring/may-2026/devops/quickstart/quickstart
ExecStart=/usr/local/bin/iii --config config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    # Systemd: caller-worker
    cat > /etc/systemd/system/caller-worker.service <<SERVICE
[Unit]
Description=iii Caller Worker (TypeScript)
After=iii-engine.service
Requires=iii-engine.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/hiring/may-2026/devops/quickstart/quickstart
ExecStart=/usr/local/bin/iii worker add ./workers/caller-worker
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable iii-engine caller-worker
    systemctl start iii-engine
    echo "API Gateway ready" > /home/ubuntu/ready.txt
    chown ubuntu:ubuntu /home/ubuntu/ready.txt
  EOF

  tags = {
    Name    = "${var.project_name}-api-gateway"
    Role    = "api-gateway"
    Project = var.project_name
  }
}

# VM 3: Inference Worker (Private Subnet)
# Runs: inference-worker (Python) + gemma-3-270m model
# NO public IP - only reachable via bastion or API GW
resource "aws_instance" "inference" {
  ami           = local.ami_id
  instance_type = "t3.micro"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.inference.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y curl wget git python3 python3-pip python3-venv unzip

    # Install Node.js 20
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs

    # Install iii CLI
    npm install -g iii

    # Clone the quickstart project
    cd /home/ubuntu
    git clone https://github.com/Alchemyst-ai/hiring.git
    cd hiring/may-2026/devops/quickstart/quickstart

    # Install Python dependencies
    cd workers/inference-worker
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install transformers torch

    # Systemd: inference-worker
    cat > /etc/systemd/system/inference-worker.service <<SERVICE
[Unit]
Description=iii Inference Worker (Python - gemma-3-270m)
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/hiring/may-2026/devops/quickstart/quickstart
ExecStart=/usr/local/bin/iii worker add ./workers/inference-worker
Restart=always
RestartSec=10
Environment="III_ENGINE_URL=ws://${aws_instance.api_gateway.private_ip}:49134"

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable inference-worker
    systemctl start inference-worker
    echo "Inference Worker ready" > /home/ubuntu/ready.txt
    chown ubuntu:ubuntu /home/ubuntu/ready.txt
  EOF

  depends_on = [
    aws_nat_gateway.nat,
    aws_instance.api_gateway
  ]

  tags = {
    Name    = "${var.project_name}-inference-worker"
    Role    = "inference"
    Project = var.project_name
  }
}

################################################################################
# OUTPUTS - printed after terraform apply
################################################################################

output "api_gateway_public_ip" {
  description = "Public IP of API Gateway VM"
  value       = aws_instance.api_gateway.public_ip
}

output "bastion_public_ip" {
  description = "Public IP of Bastion Host"
  value       = aws_instance.bastion.public_ip
}

output "inference_worker_private_ip" {
  description = "Private IP of Inference Worker"
  value       = aws_instance.inference.private_ip
}

output "inference_api_endpoint" {
  description = "Full URL to call the inference API"
  value       = "http://${aws_instance.api_gateway.public_ip}:3111/v1/chat/completions"
}

output "ssh_to_bastion" {
  description = "SSH into bastion host"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_instance.bastion.public_ip}"
}

output "ssh_to_inference_via_bastion" {
  description = "SSH into inference worker via bastion"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem -J ubuntu@${aws_instance.bastion.public_ip} ubuntu@${aws_instance.inference.private_ip}"
}

output "curl_test_command" {
  description = "Test the inference API with this curl command"
  value       = "curl -X POST http://${aws_instance.api_gateway.public_ip}:3111/v1/chat/completions -H 'Content-Type: application/json' -d '{\"messages\": [{\"role\": \"user\", \"content\": \"What is the capital of France?\"}]}'"
}
