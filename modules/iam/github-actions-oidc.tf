# Look up the provider the bootstrap script created. If this fails with
# "no matching provider found", you have not run scripts/00 yet.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_app_assume_role" {
  count = var.create_app_ci_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The sub claim is the security boundary. Only these exact refs in this
    # exact repo can assume the role — a fork or feature branch cannot.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.app_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.app_repo}:ref:refs/heads/develop",
        "repo:${var.github_org}/${var.app_repo}:environment:dev",
        "repo:${var.github_org}/${var.app_repo}:environment:qa",
        "repo:${var.github_org}/${var.app_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_app" {
  count = var.create_app_ci_role ? 1 : 0

  name                 = "${var.project}-github-actions-app-role"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_app_assume_role[0].json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project}-github-actions-app-role"
    Project = var.project
    Scope   = "account-level"
  }
}

# Push images and read cluster info. Deliberately NO kubectl apply permission —
# CI builds artifacts, ArgoCD deploys them. That separation is the point of
# GitOps and an interviewer will notice if you blur it.
resource "aws_iam_policy" "github_actions_app_policy" {
  count = var.create_app_ci_role ? 1 : 0

  name        = "${var.project}-github-actions-app-policy"
  description = "Allow ${var.app_repo} to push images to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:DescribeImageScanFindings",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"
      },
      {
        Sid      = "EKSRead"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_app_attachment" {
  count = var.create_app_ci_role ? 1 : 0

  role       = aws_iam_role.github_actions_app[0].name
  policy_arn = aws_iam_policy.github_actions_app_policy[0].arn
}
