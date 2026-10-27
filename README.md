# Deploy MariaDB and WordPress on Kamatera with OpenTofu

Deploy a WordPress demo running Apache, PHP, and MariaDB Server on [Kamatera](https://www.kamatera.com/) with **one `tofu apply`**.

The project supports either an all-in-one VM or separate web and database VMs. OpenTofu creates the infrastructure, then installs the software using its native `file` and `remote-exec` SSH provisioners—no separate Ansible playbook or manual installation command is required.

> **Scope:** This is a demonstration project, **not** a hardened production deployment. It serves WordPress over HTTP by default and needs additional work for HTTPS, secret management, access controls, database-consistent backups, and lifecycle operations.

## Architecture

### Combined mode (`split_database = false`)

```text
Internet
   |
   | HTTP :80 / SSH :22 (restricted by UFW after provisioning)
   v
Kamatera web VM (WAN)
   |-- Apache + PHP + WordPress
   `-- MariaDB Server (127.0.0.1)
```

WordPress connects to MariaDB locally. Only one Kamatera VM is created.

### Split mode (`split_database = true`)

```text
                       OpenTofu workstation
                              |
                              | SSH (agent authentication)
                              v
Internet --------------> Web VM (WAN + private LAN)
                          | Apache + PHP + WordPress
                          | SSH bastion for provisioning
                          | Private IP: 10.77.40.10
                          |
                          | Kamatera private network (10.77.40.0/24)
                          | TCP 3306 / SSH :22
                          v
                       MariaDB VM (WAN + private LAN)
                       Private IP: 10.77.40.11
                       MariaDB listens on private IP only
```

**Important Kamatera constraint:** The provider/API used by this project requires a WAN interface when creating the database VM. Accordingly, **the DB VM receives a public IP**. It is **not** a private-only server. MariaDB is configured to bind to the private interface, and the installation script enables UFW rules allowing inbound SSH and MariaDB connections only from the web VM's private IP. The DB VM uses its own WAN for outbound package downloads; **there is no NAT gateway, custom default route, or `terraform_data.web_gateway` resource**.

Because the firewall is enabled during SSH provisioning *after* the database VM is created, the WAN interface can have a temporary exposure window. Do not treat this setup as proof that the database host was never publicly reachable.

## Requirements

- A Kamatera account and API credentials with permissions to create servers and networks.
- [OpenTofu](https://opentofu.org/) (the configuration requires version 1.8 or newer).
- A local SSH agent with an SSH key whose public half will be installed on the VMs.
- Outbound network access from your workstation to Kamatera APIs and SSH access to the public web server.
- An SSH source CIDR (normally your current public IPv4 address followed by `/32`).

The configuration currently selects Ubuntu 24.04 and defaults to Frankfurt (`EU-FR`). The included `monthly_traffic_package` validation is specific to `EU-FR` (`t5000` or `b50`); review region and traffic package compatibility before using another datacenter.

## Quick start

### 1. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`, particularly:

```hcl
# true = web + DB VMs; false = all-in-one VM
split_database = true

# Replace with the public IP of the machine running tofu
ssh_cidr = "203.0.113.42/32"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"

# Example VM sizing for a disposable demo
web_cpu_cores = 1
web_ram_mb    = 2048
web_disk_gb   = 20

db_cpu_cores = 1
db_ram_mb    = 2048
db_disk_gb   = 20

# Valid for EU-FR in the tested configuration
monthly_traffic_package = "t5000"
```

The `203.0.113.42/32` CIDR is an **example**, not a working value. Replace it. In combined mode, the `db_*` sizes are not used.

The code sets the split-mode private network to `10.77.40.0/24`, with web IP `10.77.40.10` and database IP `10.77.40.11` by default. Adjust these if they conflict with your networking.

> **Naming:** The current code uses `server_name` for the web VM but fixes the other two names to `wordpress-db` and `wordpress-private`. Names must be unique in your Kamatera environment. Changing names on existing managed resources can cause unwanted updates; inspect `tofu plan` carefully.

### 2. Prepare SSH authentication

The OpenTofu SSH connections use `agent = true`. Load the **matching private key** into your local SSH agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh-add -l
```

The key referenced in `ssh_public_key_path` must correspond to the private key loaded into the agent. OpenTofu connects to the web VM directly; in split mode it reaches the database's **private IP via the web VM as an SSH bastion**.

### 3. Set Kamatera API credentials

```bash
export KAMATERA_API_CLIENT_ID="your-client-id"
export KAMATERA_API_SECRET="your-api-secret"
```

Do not commit API credentials or local `terraform.tfvars` files containing private settings.

### 4. Deploy

```bash
tofu init
tofu fmt -check -recursive
tofu validate
tofu plan
tofu apply
```

**One `tofu apply` handles both infrastructure and software provisioning.** It creates the relevant Kamatera resources and installs MariaDB, Apache, PHP, and WordPress through OpenTofu SSH provisioners. Package downloads and initialization can take some time.

Get the URL:

```bash
tofu output wordpress_installed_url
```

Open it and finish the WordPress setup wizard in your browser. The example exposes **HTTP**, not HTTPS; arrange a domain, TLS certificate, and HTTPS redirects before exposing a real site.

## What `tofu apply` does

1. Resolves the Kamatera datacenter and Ubuntu image, and generates a WordPress DB password.
2. Creates the web VM and, in split mode, the private LAN and a database VM with both WAN and LAN interfaces.
3. Runs `terraform_data.database_setup`:
   - Uses direct SSH to the web VM in combined mode, or SSH through the web VM bastion to the DB private IP in split mode.
   - Installs MariaDB Server from Ubuntu's configured APT repositories.
   - Creates a `wordpress` database and `wordpress_app` account.
   - Configures MariaDB to listen on `127.0.0.1` (combined) or the DB private IP (split).
   - In split mode, enables UFW with inbound SSH/3306 access restricted to the web VM private IP.
4. Runs `terraform_data.web_setup` after the database setup:
   - Installs Apache, PHP and WordPress.
   - Writes `wp-config.php` for the generated database credentials and chosen DB host.
   - Enables Apache configuration and UFW rules permitting HTTP/HTTPS and restricting SSH to `ssh_cidr`.
5. Produces the WordPress URL. Initial WordPress site configuration still happens in the browser.

The scripts preserve an existing `wp-config.php` on reruns. Provisioners run on resource creation or when their replacement triggers change; they are not continuous configuration management.

## Optional Kamatera services

The database VM (in **split mode only**) supports two independent options in `terraform.tfvars`:

```hcl
managed_database      = false
database_daily_backup = false
```

Set either to `true` to request Kamatera's Managed Cloud Services and/or daily VM backup option:

```hcl
managed_database      = true
database_daily_backup = true
```

These settings map to the database VM's `managed` and `daily_backup` provider arguments. They can incur additional charges. **Managed Cloud Services does not automatically mean fully managed MariaDB DBaaS**: confirm any MariaDB-specific DBA work, patching, availability, recovery, and support scope directly with Kamatera. VM-level backup is not a substitute for a verified, database-consistent backup and recovery plan.

Changing these options on an existing server may cause provider updates; review `tofu plan` before applying.

## Check MariaDB from WordPress

After completing the WordPress installation, open **Tools → Site Health → Info → Database** in the WordPress admin UI to inspect the connected database server.

Alternatively, on a host with appropriate MariaDB client access:

```sql
SELECT VERSION();
```

The exact version depends on the Ubuntu APT repositories used at deployment time. This project does not pin an upstream MariaDB release.

## Security and operational notes

- **DB WAN interface:** Mandatory for server creation in the tested Kamatera API path. The DB VM has a public IP even though MariaDB listens privately and UFW blocks unwanted inbound traffic *after setup*.
- **First-boot exposure:** UFW is applied after provisioning connects over SSH. Check cloud/network-level protections separately if first-boot isolation is required.
- **SSH:** Access to the web VM is restricted by UFW to `ssh_cidr` after the setup script runs. Use a narrow CIDR and SSH agent authentication.
- **Secrets and state:** The DB password is generated by OpenTofu and passed to the VMs during provisioning. OpenTofu state and plan files may contain secrets; encrypt/restrict them and never commit them. The temporary credential files uploaded to `/root` are removed on successful script completion; provisioning failures can leave them behind.
- **WordPress:** This demo uses plain HTTP and a browser-based initial setup. Add HTTPS, regular security updates, and an appropriate web/PHP security model for production.
- **Database backups:** Test restores, not just backups. Keep critical data somewhere outside the disposable demo VMs.
- **Managed service flags:** They configure Kamatera server options, not a MariaDB-specific managed database product.

## Troubleshooting

- **`You have to choose a WAN network (408)`**: The DB VM needs both WAN and private network blocks. Do not revert to a LAN-only database configuration.
- **`Server name is already in use (102)`**: Check the Kamatera console and `tofu state list` / `tofu plan`. In-place renames or resources created outside state can create conflicts. Avoid deleting/importing resources blindly.
- **VM initialization failures:** Kamatera's `startup_script` is intentionally minimal. Application installation happens later via `terraform_data` SSH provisioners.
- **SSH provisioner times out:** Confirm the SSH agent holds the right key, `ssh_cidr` is correct, and the web VM's public SSH is reachable. In split mode also verify that the web VM can reach the DB private IP on TCP 22.
- **Provisioning failure after VM creation:** `terraform_data` may be marked tainted or need replacement on the next apply; inspect `tofu plan`. Manually investigate and remove any temporary `/root/wordpress-*.env` files before retrying if the script failed.
- **State and console disagree:** Do not immediately delete a VM or run `tofu state rm`. First establish which real resources exist and which are tracked. State removal only makes sense for an object verified to be absent or deliberately unmanaged.
- **Changing `split_database` on a live site:** This is **not** a database migration workflow. Export/import the database and account for application configuration and downtime before switching architectures.

## Clean up

For disposable demos, use OpenTofu to remove resources it created:

```bash
tofu plan -destroy
tofu destroy
```

This **deletes the VMs and their data**. Back up anything you want to keep, and verify Kamatera's console afterward for billable resources.

## Reference

For a walkthrough and the motivation behind the project, see the related MariaDB Foundation blog post (add article link when published).

Contributions, issue reports and improvements are welcome.

