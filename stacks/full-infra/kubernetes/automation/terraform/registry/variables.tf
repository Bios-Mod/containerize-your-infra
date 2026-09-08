# Deploy to:   AWS (registry state)
# Apply:       terraform apply
# Module:      web-server
# Requires:    none
#
# Input variables for the registry Terraform state.
# Parameters modified from baseline: none

variable "aws_region" {
  description = "AWS region where the ECR repository is created"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI named profile used for authentication"
  type        = string
  default     = null
}

variable "repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "containerize-your-infra/web-server"
}

variable "image_tag_mutability" {
  description = "Whether image tags can be overwritten (MUTABLE) or not (IMMUTABLE)"
  type        = string
  default     = "IMMUTABLE"
}