locals {
  prefix = "/${var.project}/${var.env}"
}

# ─── MLflow metadata DB (RDS, Phase 1) ──────────────────────────────────────
resource "aws_secretsmanager_secret" "mlflow_db_credentials" {
  name                    = "${local.prefix}/mlflow-db-credentials"
  description             = "MLflow backend store (RDS PostgreSQL) credentials for ${var.env}"
  recovery_window_in_days = 0

  tags = {
    Name    = "${local.prefix}/mlflow-db-credentials"
    Env     = var.env
    Project = var.project
    Phase   = "1"
  }
}

resource "aws_secretsmanager_secret_version" "mlflow_db_credentials" {
  secret_id = aws_secretsmanager_secret.mlflow_db_credentials.id
  secret_string = jsonencode({
    username = var.mlflow_db_username
    password = var.mlflow_db_password
  })
}

# ─── Kafka SASL user (Strimzi, Phase 2) ─────────────────────────────────────
resource "aws_secretsmanager_secret" "kafka_credentials" {
  name                    = "${local.prefix}/kafka-credentials"
  description             = "Kafka SASL credentials for the transaction stream in ${var.env}"
  recovery_window_in_days = 0

  tags = {
    Name    = "${local.prefix}/kafka-credentials"
    Env     = var.env
    Project = var.project
    Phase   = "2"
  }
}

resource "aws_secretsmanager_secret_version" "kafka_credentials" {
  secret_id = aws_secretsmanager_secret.kafka_credentials.id
  secret_string = jsonencode({
    username = "fraud-producer"
    password = var.kafka_password
  })
}

# ─── Grafana admin (Phase 0 — used immediately) ─────────────────────────────
resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${local.prefix}/grafana-admin"
  description             = "Grafana admin credentials for ${var.env}"
  recovery_window_in_days = 0

  tags = {
    Name    = "${local.prefix}/grafana-admin"
    Env     = var.env
    Project = var.project
    Phase   = "0"
  }
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = var.grafana_admin_password
  })
}

# ─── GitOps PAT (Phase 3 — model promotion) ─────────────────────────────────
resource "aws_secretsmanager_secret" "gitops_pat" {
  name                    = "${local.prefix}/gitops-pat"
  description             = "GitHub PAT used by the retraining job to commit model promotions"
  recovery_window_in_days = 0

  tags = {
    Name    = "${local.prefix}/gitops-pat"
    Env     = var.env
    Project = var.project
    Phase   = "3"
  }
}

resource "aws_secretsmanager_secret_version" "gitops_pat" {
  secret_id = aws_secretsmanager_secret.gitops_pat.id
  secret_string = jsonencode({
    token = var.gitops_pat
  })
}