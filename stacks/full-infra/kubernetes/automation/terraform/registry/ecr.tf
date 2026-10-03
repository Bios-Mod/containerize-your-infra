# Deploy to:   AWS (registry state, independent from cluster/)
# Apply:       terraform apply
# Module:      web-server, dns
# Requires:    providers.tf, variables.tf
#
# ECR repositories for the custom images of the Kubernetes stack: web-server
# and dns. Long-lived resources, isolated from the EKS cluster state — they
# must survive every cluster up/down cycle across module implementations.
# One repository per image keeps tags and lifecycle independent.
# Parameters modified from baseline: dns repository added to the same state
#
# Note: images are built and pushed outside Terraform (see
# stacks/full-infra/kubernetes/full-infra-kubernetes.md). Terraform owns the
# repositories only; tags stay immutable.

resource "aws_ecr_repository" "web_server" {
  name                 = var.repository_name
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "containerize-your-infra"
    Module  = "web-server"
    Runtime = "kubernetes"
  }
}

resource "aws_ecr_lifecycle_policy" "web_server" {
  repository = aws_ecr_repository.web_server.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "dns" {
  name                 = var.dns_repository_name
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "containerize-your-infra"
    Module  = "dns"
    Runtime = "kubernetes"
  }
}

resource "aws_ecr_lifecycle_policy" "dns" {
  repository = aws_ecr_repository.dns.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
