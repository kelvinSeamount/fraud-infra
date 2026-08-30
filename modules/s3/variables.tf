variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID — appended to bucket names since S3 names are globally unique"
  type        = string
}

variable "create_dvc_bucket" {
  description = "Create the DVC data-versioning remote. Consumed in Phase 1."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = <<-EOT
    Versioning is on (you want to recover a clobbered model artifact), but old
    versions are expired so storage does not grow without bound.
  EOT
  type        = number
  default     = 30
}