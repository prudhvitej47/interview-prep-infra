# The bucket name contains the AWS account id, so it is passed at init time:
#   terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
# The bucket is created by bootstrap/bootstrap.sh, not by this configuration.
terraform {
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
