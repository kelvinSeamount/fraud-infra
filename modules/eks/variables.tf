variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.33"
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane ENIs and both node groups"
  type        = list(string)
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    EKS control-plane log types shipped to CloudWatch. 'audit' is what lets you
    answer "who deleted that deployment at 3am" — worth the small cost.
    Set to [] to disable entirely.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch retention for control-plane logs. Keep short — this is a lab."
  type        = number
  default     = 7
}

# ─── General node pool ──────────────────────────────────────────────────────
variable "general_instance_types" {
  description = "Instance types for the general pool (scoring service, ArgoCD, Prometheus, MLflow)"
  type        = list(string)
  default     = ["m5.large"]
}

variable "general_desired_size" {
  description = "Desired node count for the general pool"
  type        = number
  default     = 2
}

variable "general_min_size" {
  description = "Minimum node count for the general pool"
  type        = number
  default     = 2
}

variable "general_max_size" {
  description = "Maximum node count. Raise this in Phase 4 for k6 load tests."
  type        = number
  default     = 4
}

# ─── Memory-optimized node pool ─────────────────────────────────────────────
variable "memory_instance_types" {
  description = <<-EOT
    Instance types for the memory pool. r5.large gives 16 GiB at roughly
    m5.large money — the right shape for Elasticsearch and Kafka JVMs.
  EOT
  type        = list(string)
  default     = ["r5.large"]
}

variable "memory_desired_size" {
  description = "Desired node count for the memory pool"
  type        = number
  default     = 2
}

variable "memory_min_size" {
  description = "Minimum node count for the memory pool"
  type        = number
  default     = 2
}

variable "memory_max_size" {
  description = "Maximum node count for the memory pool"
  type        = number
  default     = 3
}

variable "memory_pool_taint_key" {
  description = "Taint key on the memory pool. Workloads must tolerate this to schedule there."
  type        = string
  default     = "workload"
}

variable "memory_pool_taint_value" {
  description = "Taint value on the memory pool"
  type        = string
  default     = "memory"
}

variable "node_disk_size" {
  description = "EBS root volume size (GiB) per node. Kafka/ES image layers are large."
  type        = number
  default     = 50
}