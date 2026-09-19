locals {
  # Rendered once, shipped base64-encoded because Lightsail only accepts a
  # single-line launch script. Contains secrets, so Terraform keeps it sensitive.
  first_boot_script = templatefile("${path.module}/templates/first-boot.sh.tftpl", {
    hostname             = var.name
    region               = var.region
    tailscale_auth_key   = var.tailscale_auth_key
    backup_bucket        = aws_s3_bucket.backups.bucket
    backup_access_key_id = aws_iam_access_key.backup_writer.id
    backup_secret_key    = aws_iam_access_key.backup_writer.secret
  })
}

resource "aws_lightsail_instance" "app" {
  name              = var.name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  ip_address_type   = "dualstack"

  user_data = "echo ${base64encode(local.first_boot_script)} | base64 -d > /root/interview-prep-first-boot.sh && bash /root/interview-prep-first-boot.sh"

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time_utc
    status        = "Enabled"
  }

  lifecycle {
    # The launch script only runs at first boot. A new Tailscale key or rotated
    # backup key must not silently replace the VM; replace it deliberately with
    # `terraform apply -replace=aws_lightsail_instance.app` (see docs/runbook.md).
    ignore_changes = [user_data]
  }
}

# PostgreSQL data lives on its own disk so it survives instance replacement.
resource "aws_lightsail_disk" "data" {
  name              = "${var.name}-pgdata"
  size_in_gb        = var.data_disk_size_gb
  availability_zone = var.availability_zone

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_lightsail_disk_attachment" "data" {
  disk_name     = aws_lightsail_disk.data.name
  instance_name = aws_lightsail_instance.app.name
  disk_path     = "/dev/xvdf"
}

# Replaces Lightsail's default open ports (22, 80). Nothing is served publicly:
# the app is reached only through Tailscale.
resource "aws_lightsail_instance_public_ports" "app" {
  instance_name = aws_lightsail_instance.app.name

  # Lets Tailscale peers connect directly instead of through relays.
  port_info {
    protocol   = "udp"
    from_port  = 41641
    to_port    = 41641
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # Break-glass only: SSH from the Lightsail browser console, nowhere else.
  port_info {
    protocol          = "tcp"
    from_port         = 22
    to_port           = 22
    cidr_list_aliases = ["lightsail-connect"]
  }
}

check "tailscale_auth_key_present" {
  assert {
    condition     = var.tailscale_auth_key != ""
    error_message = "TAILSCALE_AUTH_KEY is empty. An existing VM is unaffected, but a newly created VM would not join the tailnet."
  }
}
