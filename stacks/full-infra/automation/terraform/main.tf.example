# Deploy to:   AWS eu-west-1
# Apply:       terraform init → terraform plan → terraform apply
# Module:      stacks/full-infra/automation/terraform
# Requires:    terraform.tfvars (copy from terraform.tfvars.example)
#
# Provisions the EC2 host for the full-infra stack.
# Parameters modified from baseline: VPC dedicada, SG con puertos del stack

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50"
    }
  }
  required_version = ">= 1.15.6"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# ── Data Sources ──────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc_name
    Env  = "lab"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.vpc_name}-public"
    Env  = "lab"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.vpc_name}-igw"
    Env  = "lab"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.vpc_name}-rt-public"
    Env  = "lab"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# Ports match the stack exactly:
#   22   — SSH host access (restricted to operator IP)
#   80   — Traefik HTTP (redirect to HTTPS)
#   443  — Traefik HTTPS
#   2222 — file-transfer (openssh-server)
#   53   — DNS TCP/UDP (BIND9)

resource "aws_security_group" "main" {
  name        = var.security_group_name
  description = "containerize-your-infra - host access ports"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SFTP file-transfer"
    from_port   = 2222
    to_port     = 2222
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.security_group_name
    Env  = "lab"
  }
}

# ── Key Pair ──────────────────────────────────────────────────────────────────

resource "aws_key_pair" "main" {
  key_name   = var.key_pair_name
  public_key = var.public_key
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.main.id]

  user_data = file("${path.module}/user_data.sh")

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "containerize-your-infra"
    Env  = "lab"
  }
}