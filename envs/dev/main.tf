# =============================================================================
# fraud-dev — Phase 0 Foundation
#
# Provisions: vpc, eks (two node groups), s3, ecr, secrets-manager, iam
# Deferred:   rds (Phase 1), redis (Phase 2)
# Never:      anything inside Kubernetes — ArgoCD owns that, from fraud-gitops
# =============================================================================

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  project  = "fraud"
  env      = "dev"
  vpc_cidr = "10.0.0.0/16"

  public_subnet_cidrs       = ["10.0.1.0/24", "10.0.2.0/24"]
  private_eks_subnet_cidrs  = ["10.0.3.0/24", "10.0.4.0/24"]
  private_data_subnet_cidrs = ["10.0.5.0/24", "10.0.6.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  project         = "fraud"
  env             = "dev"
  cluster_version = "1.33"
  subnet_ids      = module.vpc.private_eks_subnet_ids

  # General pool — scoring service, ArgoCD, Prometheus, Grafana, Jaeger,
  # OTel Collector, and later MLflow / KServe / Argo Workflows.
  general_instance_types = ["m5.large"] # 2 vCPU / 8 GiB
  general_desired_size   = 2
  general_min_size       = 2
  general_max_size       = 4

  # Memory pool — Elasticsearch and Kafka ONLY. Tainted workload=memory:NoSchedule.
  # r5.large is 2 vCPU / 16 GiB: double the RAM of m5.large at near-identical cost.
  memory_instance_types = ["r5.large"]
  memory_desired_size   = 2
  memory_min_size       = 2
  memory_max_size       = 3

  node_disk_size = 50

  enabled_cluster_log_types  = ["api", "audit", "authenticator"]
  cluster_log_retention_days = 7
}

module "s3" {
  source = "../../modules/s3"

  project           = "fraud"
  env               = "dev"
  aws_account_id    = data.aws_caller_identity.current.account_id
  create_dvc_bucket = true
}

module "ecr" {
  source = "../../modules/ecr"

  project = "fraud"
  env     = "dev"

  repositories = [
    "scoring-service",  # KServe inference server        (Phase 1)
    "stream-producer",  # PaySim -> Kafka                (Phase 1/2)
    "feature-pipeline", # Feast materialisation          (Phase 2)
    "retraining-job",   # Argo Workflows training step   (Phase 3)
    "drift-monitor",    # Evidently drift detector       (Phase 3)
    "hello-platform",   # Phase 0 GitOps canary
  ]
}

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  project = "fraud"
  env     = "dev"

  mlflow_db_username     = "mlflowadmin"
  mlflow_db_password     = var.mlflow_db_password
  kafka_password         = var.kafka_password
  grafana_admin_password = var.grafana_admin_password
  gitops_pat             = var.gitops_pat
}

module "iam" {
  source = "../../modules/iam"

  project = "fraud"
  env     = "dev"

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_account_id    = data.aws_caller_identity.current.account_id
  aws_region        = var.aws_region

  github_org = var.github_org
  app_repo   = "fraud-backend-CI"

  # dev owns the account-level app CI role. qa and prod set this false —
  # the role is account-wide and serves all environments.
  create_app_ci_role = true

  mlflow_artifact_bucket_arn = module.s3.mlflow_bucket_arn
  dvc_bucket_arn             = module.s3.dvc_bucket_arn
}