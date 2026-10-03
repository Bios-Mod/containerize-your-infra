# Deploy to:   AWS (registry state, independent from cluster/)
# Apply:       terraform apply
# Module:      web-server (shared registry, reused by future Kubernetes modules)
# Requires:    none
#
# Provider and backend configuration for the registry Terraform state.
# Parameters modified from baseline: none

terraform {
  required_version = ">= 1.15.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}