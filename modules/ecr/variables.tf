variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
}

variable "image_tag_mutability" {
  description = <<-EOT
    IMMUTABLE by default. The retraining loop promotes models by committing an
    image tag to fraud-gitops; if tags could be overwritten, that commit would
    stop being a reliable pointer and the lineage/audit story falls apart.
  EOT
  type        = string
  default     = "IMMUTABLE"
}

variable "keep_last_images" {
  description = "Number of images to retain per repository before expiry"
  type        = number
  default     = 10
}