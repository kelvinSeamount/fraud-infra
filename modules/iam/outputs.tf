# ─── IRSA roles (per-environment) ───────────────────────────────────────────

output "eso_role_arn" {
  description = "ARN of the External Secrets Operator IRSA role"
  value       = aws_iam_role.eso_role.arn
}

output "eso_role_name" {
  description = "Name of the ESO IRSA role — scripts/01 prompts for this"
  value       = aws_iam_role.eso_role.name
}

output "argocd_role_arn" {
  description = "ARN of the ArgoCD IRSA role"
  value       = aws_iam_role.argocd_role.arn
}

output "mlflow_role_arn" {
  description = "ARN of the MLflow IRSA role — annotates the MLflow SA in Phase 1"
  value       = aws_iam_role.mlflow_role.arn
}

# ─── GitHub federation (account-level, dev only) ────────────────────────────

output "github_actions_app_role_arn" {
  description = <<-EOT
    ARN for fraud-backend-CI to assume. Set as repo variable AWS_CI_ROLE_ARN
    in that repo. Empty when create_app_ci_role = false (qa, prod).
  EOT
  value       = var.create_app_ci_role ? aws_iam_role.github_actions_app[0].arn : ""
}

output "github_oidc_provider_arn" {
  description = "ARN of the account-level GitHub OIDC provider (created by scripts/00)"
  value       = data.aws_iam_openid_connect_provider.github_actions.arn
}