output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca" {
  description = "Base64 encoded certificate authority data"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (trust anchor for all IRSA roles)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the EKS OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "cluster_security_group_id" {
  description = "SG EKS creates for managed nodes. RDS/Redis ingress rules reference this."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "general_node_group_arn" {
  description = "ARN of the general workload node group"
  value       = aws_eks_node_group.general.arn
}

output "memory_node_group_arn" {
  description = "ARN of the memory-optimized (tainted) node group"
  value       = aws_eks_node_group.memory.arn
}

output "memory_pool_selector" {
  description = "nodeSelector value Helm charts use to target the memory pool"
  value       = { workload = "memory" }
}

output "memory_pool_toleration" {
  description = "Toleration Elasticsearch/Kafka must carry to schedule on the memory pool"
  value = {
    key    = var.memory_pool_taint_key
    value  = var.memory_pool_taint_value
    effect = "NoSchedule"
  }
}