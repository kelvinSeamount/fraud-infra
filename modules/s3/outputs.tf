output "mlflow_bucket_name" {
  description = "Name of the MLflow artifact bucket"
  value       = aws_s3_bucket.mlflow_artifacts.bucket
}

output "mlflow_bucket_arn" {
  description = "ARN of the MLflow artifact bucket (consumed by the MLflow IRSA policy)"
  value       = aws_s3_bucket.mlflow_artifacts.arn
}

output "mlflow_artifact_uri" {
  description = "Value for MLflow's --default-artifact-root"
  value       = "s3://${aws_s3_bucket.mlflow_artifacts.bucket}/mlflow"
}

output "dvc_bucket_name" {
  description = "Name of the DVC remote bucket (empty if not created)"
  value       = var.create_dvc_bucket ? aws_s3_bucket.dvc_data[0].bucket : ""
}

output "dvc_bucket_arn" {
  description = "ARN of the DVC remote bucket (empty if not created)"
  value       = var.create_dvc_bucket ? aws_s3_bucket.dvc_data[0].arn : ""
}

output "dvc_remote_url" {
  description = "Value for 'dvc remote add -d storage <this>' in Phase 1"
  value       = var.create_dvc_bucket ? "s3://${aws_s3_bucket.dvc_data[0].bucket}/datasets" : ""
}