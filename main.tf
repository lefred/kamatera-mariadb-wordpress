terraform {
  required_version = ">= 1.8.0"
  required_providers {
    kamatera = { source = "Kamatera/kamatera", version = "~> 0.9.4" }
    random   = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "kamatera" {}

data "kamatera_datacenter" "selected" {
  country = var.datacenter_country
  name    = var.datacenter_name
}

data "kamatera_image" "ubuntu" {
  datacenter_id = data.kamatera_datacenter.selected.id
  os            = "Ubuntu"
  code          = "24.04 64bit"
}

resource "random_password" "wordpress_db" {
  length  = 40
  special = false
}

resource "kamatera_network" "database" {
  count         = var.split_database ? 1 : 0
  datacenter_id = data.kamatera_datacenter.selected.id
  name          = "wordpress-private"
  subnet {
    ip  = cidrhost(var.private_subnet, 0)
    bit = tonumber(split("/", var.private_subnet)[1])
  }
}

resource "kamatera_server" "web" {
  name                    = var.server_name
  datacenter_id           = data.kamatera_datacenter.selected.id
  image_id                = data.kamatera_image.ubuntu.id
  cpu_type                = "B"
  cpu_cores               = var.web_cpu_cores
  ram_mb                  = var.web_ram_mb
  disk_sizes_gb           = [var.web_disk_gb]
  billing_cycle           = "monthly"
  monthly_traffic_package = var.monthly_traffic_package
  ssh_pubkey              = trimspace(file(pathexpand(var.ssh_public_key_path)))
  power_on                = true

  # Keep VM bootstrap minimal. OpenTofu provisioners run after creation.
  # Ignore changes so adopting this version does not replace an existing VM.
  startup_script = "echo kamatera-ready > /root/provision-test.txt"
  lifecycle {
    ignore_changes = [startup_script]
  }

  network { name = "wan" }
  dynamic "network" {
    for_each = var.split_database ? [1] : []
    content {
      name = kamatera_network.database[0].full_name
      ip   = var.web_private_ip
    }
  }
}

resource "kamatera_server" "database" {
  count                   = var.split_database ? 1 : 0
  name                    = "wordpress-db"
  datacenter_id           = data.kamatera_datacenter.selected.id
  image_id                = data.kamatera_image.ubuntu.id
  cpu_type                = "B"
  cpu_cores               = var.db_cpu_cores
  ram_mb                  = var.db_ram_mb
  disk_sizes_gb           = [var.db_disk_gb]
  billing_cycle           = "monthly"
  monthly_traffic_package = var.monthly_traffic_package
  ssh_pubkey              = trimspace(file(pathexpand(var.ssh_public_key_path)))
  power_on                = true
  # Kamatera managed services
  managed = var.managed_database
  # Kamatera daily server backups
  daily_backup = var.database_daily_backup

  startup_script = "echo kamatera-ready > /root/provision-test.txt"
  lifecycle {
    ignore_changes = [startup_script]
  }

  # Kamatera requires a WAN interface during server creation.
  # The DB still communicates with WordPress only via its private interface.
  # Its WAN interface must be firewalled; it is NOT a private-only VM.
  network {
    name = "wan"
  }
  network {
    name = kamatera_network.database[0].full_name
    ip   = var.db_private_ip
  }
}

output "wordpress_public_ip" { value = try(kamatera_server.web.public_ips[0], null) }
output "wordpress_url" { value = "http://${try(kamatera_server.web.public_ips[0], "PENDING")}/" }
output "web_ssh" { value = "ssh root@${try(kamatera_server.web.public_ips[0], "PENDING")}" }
output "database_private_ip" { value = var.split_database ? var.db_private_ip : null }

output "architecture" { value = var.split_database ? "split" : "combined" }

output "web_private_ip" {
  value = var.split_database ? var.web_private_ip : null
}

# Install MariaDB via the web VM acting as SSH bastion in split mode.
resource "terraform_data" "database_setup" {
  triggers_replace = [
    var.split_database ? kamatera_server.database[0].id : kamatera_server.web.id,
    filesha256("${path.module}/provisioning/install-db.sh"),
    var.split_database,
    var.db_private_ip,
    var.web_private_ip,
    random_password.wordpress_db.id,
  ]

  connection {
    type         = "ssh"
    host         = var.split_database ? var.db_private_ip : kamatera_server.web.public_ips[0]
    user         = "root"
    agent        = true
    timeout      = "12m"
    bastion_host = var.split_database ? kamatera_server.web.public_ips[0] : null
    bastion_user = "root"
  }

  provisioner "file" {
    source      = "${path.module}/provisioning/install-db.sh"
    destination = "/root/install-db.sh"
  }

  provisioner "file" {
    destination = "/root/wordpress-db.env"
    content     = <<-ENV
      DB_PASSWORD=${random_password.wordpress_db.result}
      DB_BIND=${var.split_database ? var.db_private_ip : "127.0.0.1"}
      DB_USER_HOST=${var.split_database ? var.web_private_ip : "localhost"}
      WEB_PRIVATE_IP=${var.split_database ? var.web_private_ip : "127.0.0.1"}
      DB_PRIVATE_IP=${var.split_database ? var.db_private_ip : "127.0.0.1"}
      SPLIT_DATABASE=${var.split_database ? "true" : "false"}
    ENV
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "chmod 600 /root/wordpress-db.env",
      "chmod 700 /root/install-db.sh",
      "bash -c 'set -a; source /root/wordpress-db.env; set +a; /root/install-db.sh'",
      "rm -f /root/wordpress-db.env",
    ]
  }
}

resource "terraform_data" "web_setup" {
  depends_on = [terraform_data.database_setup]
  triggers_replace = [
    kamatera_server.web.id,
    terraform_data.database_setup.id,
    filesha256("${path.module}/provisioning/install-web.sh"),
    var.split_database,
    var.ssh_cidr,
  ]

  connection {
    type    = "ssh"
    host    = kamatera_server.web.public_ips[0]
    user    = "root"
    agent   = true
    timeout = "12m"
  }

  provisioner "file" {
    source      = "${path.module}/provisioning/install-web.sh"
    destination = "/root/install-web.sh"
  }

  provisioner "file" {
    destination = "/root/wordpress-web.env"
    content     = <<-ENV
      DB_PASSWORD=${random_password.wordpress_db.result}
      DB_HOST=${var.split_database ? var.db_private_ip : "localhost"}
      SSH_CIDR=${var.ssh_cidr}
    ENV
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "chmod 600 /root/wordpress-web.env",
      "chmod 700 /root/install-web.sh",
      "bash -c 'set -a; source /root/wordpress-web.env; set +a; /root/install-web.sh'",
      "rm -f /root/wordpress-web.env",
    ]
  }
}

output "wordpress_installed_url" {
  value      = "http://${kamatera_server.web.public_ips[0]}/"
  depends_on = [terraform_data.web_setup]
}
