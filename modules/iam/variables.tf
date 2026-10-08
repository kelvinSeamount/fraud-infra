variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (from the eks module)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider (from the eks module)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region — used to scope the ECR and Secrets Manager policies"
  type        = string
}

variable "github_org" {
  description = "GitHub username or organization that owns the three fraud repos"
  type        = string
}

variable "app_repo" {
  description = "Name of the application/model CI repo"
  type        = string
  default     = "fraud-backend-CI"
}

variable "create_app_ci_role" {
  description = <<-EOT
    Create the account-level app CI role (fraud-backend-CI -> ECR push).
    TRUE for dev only, FALSE for qa/prod — the role is account-wide, one per
    AWS account, and serves all environments.
  EOT
  type        = bool
  default     = false
}

variable "mlflow_artifact_bucket_arn" {
  description = "ARN of the MLflow artifact bucket — scopes the MLflow IRSA policy"
  type        = string
}

variable "dvc_bucket_arn" {
  description = "ARN of the DVC data bucket. Empty string if not created."
  type        = string
  default     = ""
}

variable "mlflow_namespace" {
  description = "Kubernetes namespace MLflow runs in"
  type        = string
  default     = "mlflow"
}

variable "mlflow_service_account" {
  description = "Kubernetes service account name MLflow runs as"
  type        = string
  default     = "mlflow"
}