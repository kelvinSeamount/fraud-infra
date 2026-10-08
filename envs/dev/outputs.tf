# ─── Cluster ────────────────────────────────────────────────────────────────
output "eks_cluster_name" {
  description = "EKS cluster name — use with 'aws eks update-kubeconfig'"
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Copy-paste command to point kubectl at this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "cluster_security_group_id" {
  description = "EKS-managed node SG — referenced by RDS/Redis in later phases"
  value       = module.eks.cluster_security_group_id
}

# ─── Node pools ─────────────────────────────────────────────────────────────
output "memory_pool_scheduling" {
  description = "nodeSelector + toleration that Elasticsearch and Kafka Helm values must carry"
  value = {
    nodeSelector = module.eks.memory_pool_selector
    toleration   = module.eks.memory_pool_toleration
  }
}

# ─── Networking ─────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_data_subnet_ids" {
  description = "Data-tier subnets — RDS subnet group in Phase 1"
  value       = module.vpc.private_data_subnet_ids
}

# ─── Storage ────────────────────────────────────────────────────────────────
output "mlflow_artifact_uri" {
  description = "MLflow --default-artifact-root value (Phase 1)"
  value       = module.s3.mlflow_artifact_uri
}

output "dvc_remote_url" {
  description = "DVC remote URL — 'dvc remote add -d storage <this>' (Phase 1)"
  value       = module.s3.dvc_remote_url
}

# ─── Registry ───────────────────────────────────────────────────────────────
output "ecr_registry_url" {
  description = "Base ECR registry URL for docker login"
  value       = module.ecr.registry_url
}

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = module.ecr.repository_urls
}

# ─── IAM — the values you copy into GitHub and the bootstrap scripts ────────
output "eso_role_name" {
  description = "ESO IAM role name — scripts/01 prompts for this"
  value       = module.iam.eso_role_name
}

output "eso_role_arn" {
  description = "ESO IAM role ARN — annotates the external-secrets ServiceAccount"
  value       = module.iam.eso_role_arn
}

output "mlflow_role_arn" {
  description = "MLflow IRSA role ARN — annotates the MLflow ServiceAccount (Phase 1)"
  value       = module.iam.mlflow_role_arn
}

output "github_actions_app_role_arn" {
  description = "SET THIS as repo variable AWS_CI_ROLE_ARN in fraud-backend-CI"
  value       = module.iam.github_actions_app_role_arn
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}