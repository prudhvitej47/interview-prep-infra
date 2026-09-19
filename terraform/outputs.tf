output "instance_name" {
  description = "Lightsail instance name."
  value       = aws_lightsail_instance.app.name
}

output "tailscale_hostname" {
  description = "Hostname the VM registers in the tailnet."
  value       = var.name
}

output "public_ip" {
  description = "Public IPv4 (all TCP ports are closed except Lightsail browser SSH; use Tailscale)."
  value       = aws_lightsail_instance.app.public_ip_address
}

output "data_disk_name" {
  description = "Lightsail disk holding PostgreSQL data."
  value       = aws_lightsail_disk.data.name
}

output "backup_bucket" {
  description = "S3 bucket for WAL-G archives and nightly dumps."
  value       = aws_s3_bucket.backups.bucket
}

output "backup_writer_user" {
  description = "IAM user the VM uses to write backups (key delivered at first boot)."
  value       = aws_iam_user.backup_writer.name
}
