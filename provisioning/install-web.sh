#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DB_PASSWORD:?Required}" "${DB_HOST:?Required}"
[[ $(id -u) -eq 0 ]] || { echo 'Must run as root' >&2; exit 1; }
apt-get update
apt-get install -y apache2 libapache2-mod-php php php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl curl ca-certificates python3 tar ufw
systemctl enable --now apache2
mkdir -p /var/www/wordpress
if [[ ! -f /var/www/wordpress/wp-includes/version.php ]]; then
  curl --fail --location --retry 3 --silent --show-error https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
  tar -xzf /tmp/wordpress.tar.gz -C /var/www/wordpress --strip-components=1
  rm -f /tmp/wordpress.tar.gz
fi
# Preserve an existing configured installation when re-running.
if [[ ! -f /var/www/wordpress/wp-config.php ]]; then
  WP_DB_PASSWORD="$DB_PASSWORD" WP_DB_HOST="$DB_HOST" python3 - <<'PYWORDPRESS'
import os, pathlib, re, secrets
p=pathlib.Path('/var/www/wordpress')
s=(p/'wp-config-sample.php').read_text()
for key,value in {'DB_NAME':'wordpress','DB_USER':'wordpress_app','DB_PASSWORD':os.environ['WP_DB_PASSWORD'],'DB_HOST':os.environ['WP_DB_HOST']}.items():
    pat=r"define\(\s*['\"]"+key+r"['\"]\s*,\s*['\"][^'\"]*['\"]\s*\);"
    s,count=re.subn(pat,lambda m:"define( '"+key+"', '"+value+"' );",s,count=1)
    if count!=1: raise RuntimeError('Cannot configure '+key)
for key in ('AUTH_KEY','SECURE_AUTH_KEY','LOGGED_IN_KEY','NONCE_KEY','AUTH_SALT','SECURE_AUTH_SALT','LOGGED_IN_SALT','NONCE_SALT'):
    pat=r"define\(\s*['\"]"+key+r"['\"]\s*,\s*['\"]put your unique phrase here['\"]\s*\);"
    s,count=re.subn(pat,lambda m:"define( '"+key+"', '"+secrets.token_hex(64)+"' );",s,count=1)
    if count!=1: raise RuntimeError('Cannot configure salt '+key)
(p/'wp-config.php').write_text(s)
PYWORDPRESS
fi
chown -R root:www-data /var/www/wordpress
find /var/www/wordpress -type d -exec chmod 755 {} +
find /var/www/wordpress -type f -exec chmod 644 {} +
chmod 640 /var/www/wordpress/wp-config.php
chown -R www-data:www-data /var/www/wordpress/wp-content
cat >/etc/apache2/sites-available/wordpress.conf <<'APACHE'
<VirtualHost *:80>
    ServerName wordpress.local
    DocumentRoot /var/www/wordpress
    <Directory /var/www/wordpress>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/wordpress-error.log
    CustomLog ${APACHE_LOG_DIR}/wordpress-access.log combined
</VirtualHost>
APACHE
a2enmod rewrite headers
a2dissite 000-default.conf || true
a2ensite wordpress.conf
apache2ctl configtest
systemctl reload apache2
# Do not enable UFW before ensuring SSH connectivity is allowed.
: "${SSH_CIDR:?Required}"
ufw allow from "$SSH_CIDR" to any port 22 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
systemctl is-active --quiet apache2
echo 'Apache and WordPress files ready; complete installation in the browser'
