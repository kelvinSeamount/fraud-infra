variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnets — NAT Gateway, NLB, ingress"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_eks_subnet_cidrs" {
  description = "Private subnets for EKS worker nodes (both node groups)"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = <<-EOT
    Private data-tier subnets. Holds RDS (MLflow metadata backend, Phase 1) and
    ElastiCache if the Feast online store is ever moved out of the cluster.
    Renamed from Infra-Zen's private_rds_* because it is no longer RDS-only.
  EOT
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]
}
