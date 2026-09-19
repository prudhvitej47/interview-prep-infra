provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = "interview-prep"
      managed-by = "terraform"
      repo       = "prudhvitej47/interview-prep-infra"
    }
  }
}
