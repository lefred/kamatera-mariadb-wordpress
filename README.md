# Kamatera WordPress with OpenTofu: public web VM, private MariaDB VM

One `tofu apply` provisions infrastructure **and** installs the application using OpenTofu's built-in SSH `file`/`remote-exec` provisioners (not an external provisioning tool).

## Modes

* `split_database = false`: one public VM running Apache, PHP, WordPress and local MariaDB.
* `split_database = true`: web VM with public WAN + private LAN, database VM with **private LAN only**. The web VM acts as SSH bastion and outbound NAT gateway for the DB VM, allowing package installation without public DB access.

Web private IP: `10.77.40.10`; DB private IP: `10.77.40.11` (configurable). DB UFW permits TCP 22 and 3306 only from the web VM's private IP. The public web VM restricts SSH to `ssh_cidr` and allows ports 80/443.

## Deploy from scratch

1. In the Kamatera console, verify that old demo VMs have been deleted. If state still tracks a deleted resource, use `tofu state rm kamatera_server.web` (or the matching address). Back up state before changing it; never remove state for a server that still exists.
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and set `split_database = true` for a private DB (or false for combined), `ssh_cidr` to your current public IP /32, and SSH public key path.
3. Have an SSH agent running **with the private key matching `ssh_public_key_path`**:
   ```sh
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   ssh-add -l
   ```
4. Export `KAMATERA_API_CLIENT_ID` and `KAMATERA_API_SECRET` in your shell.
5. Run:
   ```sh
   tofu init
   tofu fmt -check -recursive
   tofu validate
   tofu plan
   tofu apply
   tofu output wordpress_installed_url
   ```
6. Open the URL and complete the WordPress installer in the browser. HTTP only by default (demo).

## Provisioning order

1. Kamatera private LAN, web VM, DB VM (split mode).
2. `terraform_data.web_gateway`: install outbound NAT + UFW forwarding rule on web VM.
3. `terraform_data.database_setup`: SSH through bastion, configure DB default route via web private IP, apt-install and configure MariaDB.
4. `terraform_data.web_setup`: SSH into web VM, install Apache/PHP/WordPress, enable web firewall, reassert NAT rules.

