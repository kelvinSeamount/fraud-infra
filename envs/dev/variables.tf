variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "eu-central-1"
}

variable "github_org" {
  description = "GitHub username or organization that owns the three fraud repos"
  type        = string
  default     = "kelvinSeamount"
}

# ─── Secrets (supplied via TF_VAR_* — never committed) ──────────────────────

variable "mlflow_db_password" {
  description = "Master password for the MLflow metadata database (RDS, Phase 1)"
  type        = string
  sensitive   = true
}

variable "kafka_password" {
  description = "SASL password for the Kafka producer user (Phase 2)"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password — consumed via ESO in Phase 0"
  type        = string
  sensitive   = true
}

variable "gitops_pat" {
  description = "GitHub PAT with write access to fraud-gitops (Phase 3 promotion)"
  type        = string
  sensitive   = true
}