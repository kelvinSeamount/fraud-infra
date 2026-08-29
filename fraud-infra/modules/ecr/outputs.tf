output "repository_urls" {
  description = "Map of repository name to repository URL"
  value       = { for name, repo in aws_ecr_repository.main : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repository name to ARN"
  value       = { for name, repo in aws_ecr_repository.main : name => repo.arn }
}

output "registry_url" {
  description = "Base registry URL — <account>.dkr.ecr.<region>.amazonaws.com"
  value       = length(var.repositories) > 0 ? split("/", values(aws_ecr_repository.main)[0].repository_url)[0] : ""
}