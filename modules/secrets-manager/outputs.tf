output "secret_prefix" {
  description = "Shared Secrets Manager path prefix for this environment"
  value       = "/${var.project}/${var.env}"
}

output "mlflow_db_secret_arn" {
  description = "ARN of the MLflow database credentials secret"
  value       = aws_secretsmanager_secret.mlflow_db_credentials.arn
}

output "kafka_secret_arn" {
  description = "ARN of the Kafka SASL credentials secret"
  value       = aws_secretsmanager_secret.kafka_credentials.arn
}

output "grafana_admin_secret_arn" {
  description = "ARN of the Grafana admin credentials secret"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "gitops_pat_secret_arn" {
  description = "ARN of the GitOps PAT secret"
  value       = aws_secretsmanager_secret.gitops_pat.arn
}