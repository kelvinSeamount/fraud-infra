variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "mlflow_db_username" {
  description = "Master username for the MLflow metadata database (RDS, Phase 1)"
  type        = string
  default     = "mlflowadmin"
  sensitive   = true
}

variable "mlflow_db_password" {
  description = "Master password for the MLflow metadata database"
  type        = string
  sensitive   = true
}

variable "kafka_password" {
  description = "SASL password for the Strimzi Kafka user (Phase 2)"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password — consumed via ESO in Phase 0"
  type        = string
  sensitive   = true
}

variable "gitops_pat" {
  description = <<-EOT
    GitHub PAT with write access to fraud-gitops. The Phase 3 retraining job
    uses this to commit a model promotion. Stored now so the retraining
    pipeline needs no new infra later.
  EOT
  type        = string
  sensitive   = true
}