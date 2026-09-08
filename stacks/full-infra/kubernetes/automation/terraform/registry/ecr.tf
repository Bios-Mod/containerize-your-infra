# Deploy to:   AWS (registry state, independent from cluster/)
# Apply:       terraform apply
# Module:      web-server
# Requires:    providers.tf, variables.tf
#
# ECR repository for the web-server custom image. Long-lived resource, isolated
# from the EKS cluster state — must survive every cluster up/down cycle across
# module implementations.
# Parameters modified from baseline: none

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