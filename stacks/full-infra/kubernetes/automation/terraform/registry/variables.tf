# Deploy to:   AWS (registry state)
# Apply:       terraform apply
# Module:      web-server, dns
# Requires:    none
#
# Input variables for the registry Terraform state.
# Parameters modified from baseline: dns_repository_name added

variable "aws_region" {
  description = "AWS region where the ECR repositories are created"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI named profile used for authentication"
  type        = string
  default     = null
}

variable "repository_name" {
  description = "ECR repository name for the web-server image"
  type        = string
  default     = "containerize-your-infra/web-server"
}

variable "dns_repository_name" {
  description = "ECR repository name for the dns image"
  type        = string
  default     = "containerize-your-infra/dns"
}

variable "image_tag_mutability" {
  description = "Whether image tags can be overwritten (MUTABLE) or not (IMMUTABLE)"
  type        = string
  default     = "IMMUTABLE"
}
