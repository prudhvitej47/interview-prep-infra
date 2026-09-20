data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "backups" {
  bucket = "interview-prep-backups-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Nightly pg_dump files. WAL-G manages its own retention under wal-g/.
  rule {
    id     = "expire-nightly-dumps"
    status = "Enabled"
    filter {
      prefix = "dumps/"
    }
    expiration {
      days = var.backup_retention_days
    }
  }

  # Versioning keeps deleted or overwritten objects; clear them after the window.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {
      prefix = ""
    }
    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {
      prefix = ""
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

data "aws_iam_policy_document" "backups_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# Lightsail instances cannot assume IAM roles, so the VM gets a narrowly scoped
# IAM user whose key is written to /etc/interview-prep/backup.env at first boot.
resource "aws_iam_user" "backup_writer" {
  name = "backup-writer"
  path = "/interview-prep/"
}

data "aws_iam_policy_document" "backup_writer" {
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "ReadWriteBackupObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  # The VM pulls its images with this same key. Lightsail instances cannot assume a role, and
  # user_data only runs at first boot, so a brand-new key would have no way onto the server that
  # did not involve a human pasting a secret. This key is already there, written at first boot.
  # The grant is read-only and limited to these two repositories.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullOwnImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
}

resource "aws_iam_user_policy" "backup_writer" {
  name   = "backup-writer-s3"
  user   = aws_iam_user.backup_writer.name
  policy = data.aws_iam_policy_document.backup_writer.json
}

resource "aws_iam_access_key" "backup_writer" {
  user = aws_iam_user.backup_writer.name
}
