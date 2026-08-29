locals {
  # The OIDC issuer host with the scheme stripped. IAM condition keys are built
  # from this bare form, e.g. "oidc.eks.eu-central-1.amazonaws.com/id/ABC:sub"
  oidc_host = replace(var.oidc_provider_url, "https://", "")
}

# ─── External Secrets Operator ──────────────────────────────────────────────
data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso_role" {
  name               = "${var.project}-${var.env}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-eso-role"
    Env     = var.env
    Project = var.project
  }
}

# Scoped to /fraud/* — ESO can read this platform's secrets and nothing else in
# the account. This is why the shared secret prefix convention matters.
resource "aws_iam_policy" "eso_secrets_policy" {
  name        = "${var.project}-${var.env}-eso-secrets-policy"
  description = "Allow External Secrets Operator to read /${var.project}/* secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadFraudSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:/${var.project}/*"
      },
      {
        Sid      = "ListSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eso_secrets_attachment" {
  role       = aws_iam_role.eso_role.name
  policy_arn = aws_iam_policy.eso_secrets_policy.arn
}

# ─── ArgoCD ─────────────────────────────────────────────────────────────────
# Role exists with no policy attached yet, on purpose. ArgoCD needs no AWS
# access to sync manifests from Git — it only needs one if you later add the
# ECR image-updater. Creating the trust relationship now means that upgrade is
# a policy attachment, not a re-plumb.
data "aws_iam_policy_document" "argocd_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argocd_role" {
  name               = "${var.project}-${var.env}-argocd-role"
  assume_role_policy = data.aws_iam_policy_document.argocd_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-argocd-role"
    Env     = var.env
    Project = var.project
  }
}

# ─── MLflow (Phase 1 consumer, trust created in Phase 0) ────────────────────
data "aws_iam_policy_document" "mlflow_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.mlflow_namespace}:${var.mlflow_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mlflow_role" {
  name               = "${var.project}-${var.env}-mlflow-role"
  assume_role_policy = data.aws_iam_policy_document.mlflow_assume_role.json

  tags = {
    Name    = "${var.project}-${var.env}-mlflow-role"
    Env     = var.env
    Project = var.project
  }
}

# Scoped to the artifact bucket only. MLflow has no business reading any other
# bucket in the account — including the Terraform state bucket.
resource "aws_iam_policy" "mlflow_s3_policy" {
  name        = "${var.project}-${var.env}-mlflow-s3-policy"
  description = "Allow MLflow to read/write model artifacts in its own bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ListArtifactBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = var.mlflow_artifact_bucket_arn
        },
        {
          Sid    = "ReadWriteArtifacts"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts",
          ]
          Resource = "${var.mlflow_artifact_bucket_arn}/*"
        },
      ],
      # DVC remote access, only if the bucket was created. The training and
      # retraining jobs reuse this role to pull versioned datasets.
      var.dvc_bucket_arn == "" ? [] : [
        {
          Sid      = "ListDvcBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = var.dvc_bucket_arn
        },
        {
          Sid    = "ReadWriteDvcData"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts",
          ]
          Resource = "${var.dvc_bucket_arn}/*"
        },
      ]
    )
  })
}

resource "aws_iam_role_policy_attachment" "mlflow_s3_attachment" {
  role       = aws_iam_role.mlflow_role.name
  policy_arn = aws_iam_policy.mlflow_s3_policy.arn
}
