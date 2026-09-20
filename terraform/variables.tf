variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zone" {
  description = "Lightsail availability zone. The instance and its data disk must share it."
  type        = string
  default     = "ap-south-1a"
}

variable "name" {
  description = "Base name for Lightsail resources and the Tailscale hostname."
  type        = string
  default     = "interview-prep"
}

variable "bundle_id" {
  description = "Lightsail plan. small_3_1 = 2 vCPU, 2 GB RAM, 60 GB SSD, IPv4 + IPv6 ($12/month). Confirm with the bootstrap script's bundle table."
  type        = string
  default     = "small_3_1"
}

variable "blueprint_id" {
  description = "Lightsail OS image."
  type        = string
  default     = "ubuntu_24_04"
}

variable "data_disk_size_gb" {
  description = "Size of the separate disk that holds PostgreSQL data."
  type        = number
  default     = 8
}

variable "snapshot_time_utc" {
  description = "Daily automatic snapshot time, HH:00 in UTC. 20:00 UTC = 01:30 IST."
  type        = string
  default     = "20:00"
}

variable "backup_retention_days" {
  description = "Days to keep nightly dumps and old object versions in the backup bucket."
  type        = number
  default     = 30
}

variable "tailscale_auth_key" {
  description = "One-off, pre-approved Tailscale auth key. Only read when the instance is first created."
  type        = string
  sensitive   = true
  default     = ""
}
