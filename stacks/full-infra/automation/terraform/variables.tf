variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
  default     = "default"
}

variable "ec2_instance_type" {
  description = "EC2 instance type — must be ARM64"
  type        = string
  default     = "t4g.micro"
}

variable "vpc_name" {
  description = "Name tag for the VPC and derived resources"
  type        = string
  default     = "containerize-vpc"
}

variable "security_group_name" {
  description = "Name tag for the security group"
  type        = string
  default     = "containerize-sg"
}

variable "key_pair_name" {
  description = "Name for the AWS key pair resource"
  type        = string
  default     = "containerize-key"
}

variable "public_key" {
  description = "SSH public key content (e.g. contents of ~/.ssh/id_ed25519.pub)"
  type        = string
  sensitive   = true
}