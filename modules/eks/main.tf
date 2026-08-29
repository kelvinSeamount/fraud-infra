# =============================================================================
# EKS cluster with SPLIT node groups.
#
#   general  -> scoring service, ArgoCD, Prometheus, MLflow, KServe
#   memory   -> Elasticsearch, Kafka (Strimzi)   [TAINTED]
#
# The taint is the load-bearing part. Without it, a Kafka rebalance or an
# Elasticsearch heap spike can create node memory pressure that evicts the
# latency-critical scoring pod. The taint makes that co-scheduling impossible.
# =============================================================================

data "aws_partition" "current" {}

# ─── IAM: control plane role ────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.project}-${var.env}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project}-${var.env}-eks-cluster-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ─── IAM: shared node role ──────────────────────────────────────────────────
# Both node groups share one role. The pools differ in *scheduling* (labels and
# taints), not in *permissions* — an Elasticsearch node needs no more AWS access
# than a scoring node. Splitting the role too would be complexity without value.
resource "aws_iam_role" "node_group" {
  name = "${var.project}-${var.env}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project}-${var.env}-eks-node-group-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# ─── CloudWatch log group ───────────────────────────────────────────────────
# Created explicitly so retention is bounded. Let EKS create it implicitly and
# it defaults to "never expire", quietly accruing cost forever.
resource "aws_cloudwatch_log_group" "eks" {
  count             = length(var.enabled_cluster_log_types) > 0 ? 1 : 0
  name              = "/aws/eks/${var.project}-${var.env}-cluster/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = {
    Name    = "${var.project}-${var.env}-eks-logs"
    Env     = var.env
    Project = var.project
  }
}

# ─── EKS cluster ────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = "${var.project}-${var.env}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_cloudwatch_log_group.eks,
  ]

  tags = {
    Name    = "${var.project}-${var.env}-cluster"
    Env     = var.env
    Project = var.project
  }
}

# ─── Node group 1: GENERAL ──────────────────────────────────────────────────
# Untainted. Everything schedules here by default.
resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-${var.env}-general"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.general_instance_types
  disk_size       = var.node_disk_size

  labels = {
    workload = "general"
  }

  scaling_config {
    desired_size = var.general_desired_size
    min_size     = var.general_min_size
    max_size     = var.general_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # desired_size drifts when the autoscaler or HPA scales the group. Without
  # this, every plan would try to scale it back and fight the autoscaler.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]

  tags = {
    Name    = "${var.project}-${var.env}-general"
    Env     = var.env
    Project = var.project
    Pool    = "general"
  }
}

# ─── Node group 2: MEMORY-OPTIMIZED (tainted) ───────────────────────────────
# Reserved for Elasticsearch and Kafka. NO_SCHEDULE means nothing lands here
# unless it explicitly tolerates workload=memory
# and Strimzi Helm values carry that toleration plus a nodeSelector.
resource "aws_eks_node_group" "memory" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-${var.env}-memory"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.memory_instance_types
  disk_size       = var.node_disk_size

  labels = {
    workload = "memory"
  }

  taint {
    key    = var.memory_pool_taint_key
    value  = var.memory_pool_taint_value
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    desired_size = var.memory_desired_size
    min_size     = var.memory_min_size
    max_size     = var.memory_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]

  tags = {
    Name    = "${var.project}-${var.env}-memory"
    Env     = var.env
    Project = var.project
    Pool    = "memory"
  }
}

# ─── OIDC provider for IRSA ─────────────────────────────────────────────────
# The trust anchor for every "pod assumes an IAM role" story in the platform:
# ESO reading Secrets Manager, MLflow writing to S3, Feast later.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name    = "${var.project}-${var.env}-oidc-provider"
    Env     = var.env
    Project = var.project
  }
}

# ─── EBS CSI driver ─────────────────────────────────────────────────────────
# Mandatory here, not optional. Every stateful piece of this platform wants a
# PersistentVolume: Elasticsearch data, Kafka logs, Prometheus TSDB, Grafana.
# The in-tree provisioner was removed in K8s 1.23, so without this driver every
# PVC stays Pending forever and you lose an evening to it.
locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-${var.env}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Condition = {
          StringEquals = {
            "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project}-${var.env}-ebs-csi-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.general,
    aws_eks_node_group.memory,
  ]

  tags = {
    Name    = "${var.project}-${var.env}-ebs-csi-addon"
    Env     = var.env
    Project = var.project
  }
}
