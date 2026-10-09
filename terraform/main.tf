terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

variable "admin_cidr" {
  description = "Your public IPv4 address in CIDR notation, e.g. 203.0.113.10/32"
  type        = string
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC
resource "aws_vpc" "monitoring_vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "monitoring-vpc"
    Project = "Grafana-Prometheus"
  }
}

# Public subnet for the monitoring and target servers
resource "aws_subnet" "monitoring_public_subnet" {
  vpc_id                  = aws_vpc.monitoring_vpc.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "monitoring-public-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "monitoring_igw" {
  vpc_id = aws_vpc.monitoring_vpc.id

  tags = {
    Name = "monitoring-igw"
  }
}

# Public route table
resource "aws_route_table" "monitoring_public_rt" {
  vpc_id = aws_vpc.monitoring_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.monitoring_igw.id
  }

  tags = {
    Name = "monitoring-public-route-table"
  }
}

resource "aws_route_table_association" "monitoring_public_rta" {
  subnet_id      = aws_subnet.monitoring_public_subnet.id
  route_table_id = aws_route_table.monitoring_public_rt.id
}

# Monitoring server security group
resource "aws_security_group" "monitoring_sg" {
  name        = "grafana-prometheus-monitoring-sg"
  description = "Restricted access to monitoring server"
  vpc_id      = aws_vpc.monitoring_vpc.id

  tags = {
    Name = "grafana-prometheus-monitoring-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_ssh" {
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "SSH from administrator"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "grafana_access" {
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Grafana dashboard from administrator"
  cidr_ipv4         = var.admin_cidr
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "prometheus_access" {
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Prometheus UI from administrator"
  cidr_ipv4         = var.admin_cidr
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_outbound" {
  security_group_id = aws_security_group.monitoring_sg.id
  description       = "Allow outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Target server security group
resource "aws_security_group" "target_sg" {
  name        = "monitoring-target-sg"
  description = "Target server access"
  vpc_id      = aws_vpc.monitoring_vpc.id

  tags = {
    Name = "monitoring-target-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "target_ssh" {
  security_group_id = aws_security_group.target_sg.id
  description       = "SSH from administrator"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_exporter_access" {
  security_group_id            = aws_security_group.target_sg.id
  description                  = "Node Exporter access from monitoring server only"
  referenced_security_group_id = aws_security_group.monitoring_sg.id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "target_outbound" {
  security_group_id = aws_security_group.target_sg.id
  description       = "Allow outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EC2 instance 1: Prometheus + Grafana + log monitoring
resource "aws_instance" "monitoring_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  key_name                    = "my key"
  subnet_id                   = aws_subnet.monitoring_public_subnet.id
  vpc_security_group_ids      = [aws_security_group.monitoring_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 12
    delete_on_termination = true
  }

  tags = {
    Name    = "grafana-prometheus-server"
    Project = "Grafana-Prometheus"
  }
}

# EC2 instance 2: server to monitor
resource "aws_instance" "target_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  key_name                    = "my key"
  subnet_id                   = aws_subnet.monitoring_public_subnet.id
  vpc_security_group_ids      = [aws_security_group.target_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }

  tags = {
    Name    = "prometheus-target-server"
    Project = "Grafana-Prometheus"
  }
}

output "vpc_id" {
  value = aws_vpc.monitoring_vpc.id
}

output "monitoring_public_ip" {
  value = aws_instance.monitoring_server.public_ip
}

output "monitoring_private_ip" {
  value = aws_instance.monitoring_server.private_ip
}

output "target_public_ip" {
  value = aws_instance.target_server.public_ip
}

output "target_private_ip" {
  value = aws_instance.target_server.private_ip
}

output "grafana_url" {
  value = "http://${aws_instance.monitoring_server.public_ip}:3000"
}

output "prometheus_url" {
  value = "http://${aws_instance.monitoring_server.public_ip}:9090"
}