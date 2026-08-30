# Backend configuration.
terraform {
  backend "s3" {
    bucket       = "fraud-infra-tf-state-kelvinseamount"
    key          = "envs/dev/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}