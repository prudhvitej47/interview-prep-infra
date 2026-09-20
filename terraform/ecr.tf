# Where the app image and the validated content bundle are published.
#
# Images are pushed only by GitHub Actions on main, using the interview-prep-ecr-push role that
# bootstrap.sh creates. The VM pulls them with the backup-writer key it already holds, so no new
# credential ever has to reach the server.

locals {
  ecr_repositories = {
    app     = "${var.name}-app"
    content = "${var.name}-content"
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name = each.value

  # Mutable on purpose: every build pushes an immutable <commit-sha> tag and also moves a "main"
  # tag to it. The moving tag is how the VM's update timer notices a new build without being told.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Keep the last 10 images. Tagged by push date, so the newest — the one the VM is running — is
# never the one expired.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
