variable "datacenter_country" {
  type    = string
  default = "Germany"
}
variable "datacenter_name" {
  type    = string
  default = "Frankfurt"
}
variable "server_name" {
  type    = string
  default = "wordpress"
}
variable "split_database" {
  description = "false: Apache, WordPress and MariaDB on one VM; true: dedicated MariaDB VM connected over private LAN."
  type        = bool
  default     = false
}
variable "web_cpu_cores" {
  type    = number
  default = 2
}
variable "web_ram_mb" {
  type    = number
  default = 4096
}
variable "web_disk_gb" {
  type    = number
  default = 30
}
variable "db_cpu_cores" {
  type    = number
  default = 2
}
variable "db_ram_mb" {
  type    = number
  default = 4096
}
variable "db_disk_gb" {
  type    = number
  default = 30
}
variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}
variable "ssh_cidr" {
  type        = string
  description = "Your public IPv4 address /32 for SSH."
  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0))
    error_message = "Set a valid IPv4 or IPv6 CIDR."
  }
}
variable "private_subnet" {
  type    = string
  default = "10.77.40.0/24"
  validation {
    condition     = can(cidrhost(var.private_subnet, 5))
    error_message = "Specify a usable private CIDR."
  }
}
variable "web_private_ip" {
  type    = string
  default = "10.77.40.10"
}
variable "db_private_ip" {
  type    = string
  default = "10.77.40.11"
}

variable "monthly_traffic_package" {
  description = "Kamatera monthly bandwidth package for the chosen datacenter (EU-FR supports t5000 or b50)."
  type        = string
  default     = "t5000"
  validation {
    condition     = contains(["t5000", "b50"], var.monthly_traffic_package)
    error_message = "Supported packages for EU-FR: t5000 or b50."
  }
}

variable "managed_database" {
  description = "Enable Kamatera Managed Cloud Services for MariaDB"
  type        = bool
  default     = false
}

variable "database_daily_backup" {
  description = "Enable Kamatera daily backups for the database VM"
  type        = bool
  default     = false
}
