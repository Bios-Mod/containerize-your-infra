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

variable "cluster_name" {
  description = "Name of the EKS cluster and prefix for every derived resource"
  type        = string
  default     = "full-infra"
}

variable "kubernetes_version" {
  description = "EKS control plane version, pinned for reproducibility"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability Zones used by the public and private subnet pairs"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets (NAT Gateways), one per AZ"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the two private subnets (worker nodes), one per AZ"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the Managed Node Group — ARM64, same architecture family as the Docker/EC2 host"
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "node_ami_type" {
  description = "EKS-optimized AMI type for the Managed Node Group. AL2023 family — AL2_ARM_64 is only valid for Kubernetes 1.32 or earlier and is deprecated by AWS"
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_count" {
  description = "Fixed node count — min, max and desired size are all equal for this lab, no autoscaling behavior"
  type        = number
  default     = 2
}