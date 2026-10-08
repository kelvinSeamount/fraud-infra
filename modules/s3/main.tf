locals {
  mlflow_bucket_name = "${var.project}-${var.env}-mlflow-artifacts-${var.aws_account_id}"
  dvc_bucket_name    = "${var.project}-${var.env}-dvc-data-${var.aws_account_id}"

  # Outside prod, allow terraform destroy to remove a non-empty bucket. This is
  # what makes the "destroy at end of day" discipline actually work.
  allow_force_destroy = var.env != "prod"
}

# ─── MLflow artifact store ──────────────────────────────────────────────────
resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket        = local.mlflow_bucket_name
  force_destroy = local.allow_force_destroy

  tags = {
    Name    = local.mlflow_bucket_name
    Env     = var.env
    Project = var.project
    Purpose = "mlflow-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ─── DVC data remote (Phase 1 consumer) ─────────────────────────────────────
resource "aws_s3_bucket" "dvc_data" {
  count         = var.create_dvc_bucket ? 1 : 0
  bucket        = local.dvc_bucket_name
  force_destroy = local.allow_force_destroy

  tags = {
    Name    = local.dvc_bucket_name
    Env     = var.env
    Project = var.project
    Purpose = "dvc-data-versioning"
  }
}

resource "aws_s3_bucket_versioning" "dvc_data" {
  count  = var.create_dvc_bucket ? 1 : 0
  bucket = aws_s3_bucket.dvc_data[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dvc_data" {
  count  = var.create_dvc_bucket ? 1 : 0
  bucket = aws_s3_bucket.dvc_data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "dvc_data" {
  count  = var.create_dvc_bucket ? 1 : 0
  bucket = aws_s3_bucket.dvc_data[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}