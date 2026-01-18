#!/usr/bin/env bash
# install-opencart-ubuntu24.sh
# OpenCart 4.1.0.3 on Ubuntu 24.04.x (Apache + PHP-FPM + MySQL)
# Defensive / admin automation only. Review before running.

set -Eeuo pipefail

# -----------------------------
# User-configurable variables
# -----------------------------
SERVER_NAME="${SERVER_NAME:-shop.example.com}"     # Used for global Apache ServerName + vhost
SERVER_ALIAS="${SERVER_ALIAS:-www.shop.example.com}"
OPENCART_VERSION="${OPENCART_VERSION:-4.1.0.3}"
DB_NAME="${DB_NAME:-opencart}"
DB_USER="${DB_USER:-opencart}"
DB_PASS="${DB_PASS:-password}"                    # CHANGE THIS
WEB_ROOT="${WEB_ROOT:-/var/www/opencart}"
TMPDIR="${TMPDIR:-/tmp/opencart_install}"

# SourceForge mirror URL (stable enough for scripting)
OPENCART_URL="https://sourceforge.net/projects/opencart.mirror/files/${OPENCART_VERSION}/opencart-${OPENCART_VERSION}.zip/download"

# -----------------------------
# Helpers
# -----------------------------
log() { printf "\n[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

need_root_for() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# Pre-flight checks
# -----------------------------
log "Pre-flight checks"

if ! command_exists apt; then
  echo "Error: apt not found. This script is for Ubuntu/Debian." >&2
  exit 1
fi

if [[ "$DB_PASS" == "password" ]]; then
  echo "Error: DB_PASS is set to the default 'password'. Set DB_PASS to a strong value." >&2
  echo "Example: DB_PASS='a-strong-password' ./install-opencart-ubuntu24.sh" >&2
  exit 1
fi

# -----------------------------
# 1) System update + packages
# -----------------------------
log "Updating system and installing packages"
need_root_for apt update
need_root_for apt -y upgrade

need_root_for apt install -y \
  apache2 mysql-server \
  php php-fpm libapache2-mod-fcgid \
  php-mysql php-curl php-xml php-zip php-gd php-mbstring php-intl \
  unzip wget rsync

# -----------------------------
# 2) Apache modules + PHP-FPM conf
# -----------------------------
log "Enabling Apache modules and PHP-FPM config"
need_root_for a2enmod proxy_fcgi setenvif rewrite

# Enable whichever php*-fpm conf exists (e.g., php8.3-fpm)
# Using shell expansion; safe because we validate via a2queryconf below.
need_root_for bash -c 'a2enconf php*-fpm >/dev/null'

need_root_for systemctl enable --now apache2

# Ensure php-fpm service is running (Ubuntu 24.04 default is typically php8.3-fpm)
PHP_FPM_SVC="$(systemctl list-unit-files | awk '/^php[0-9]+\.[0-9]+-fpm\.service/ {print $1; exit}')"
if [[ -n "${PHP_FPM_SVC}" ]]; then
  log "Ensuring PHP-FPM is enabled and running: ${PHP_FPM_SVC}"
  need_root_for systemctl enable --now "${PHP_FPM_SVC}"
else
  log "Warning: Could not auto-detect phpX.Y-fpm service name. Proceeding anyway."
fi

need_root_for systemctl restart apache2

# -----------------------------
# 3) Suppress Apache FQDN warning with global ServerName
# -----------------------------
log "Configuring global Apache ServerName: ${SERVER_NAME}"
need_root_for bash -c "echo 'ServerName ${SERVER_NAME}' > /etc/apache2/conf-available/servername.conf"
need_root_for a2enconf servername
need_root_for systemctl reload apache2

# -----------------------------
# 4) MySQL database + user
# -----------------------------
log "Creating MySQL database and user"
SQL="$(cat <<SQL_EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL_EOF
)"
need_root_for mysql -e "$SQL"

# -----------------------------
# 5) Download and install OpenCart
# -----------------------------
log "Downloading OpenCart ${OPENCART_VERSION} to ${TMPDIR}"
need_root_for rm -rf "${TMPDIR}"
need_root_for mkdir -p "${TMPDIR}"
need_root_for bash -c "cd '${TMPDIR}' && wget -qO opencart.zip '${OPENCART_URL}'"
need_root_for bash -c "cd '${TMPDIR}' && unzip -q opencart.zip -d opencart-src"

log "Deploying OpenCart to ${WEB_ROOT}"
need_root_for mkdir -p "${WEB_ROOT}"
need_root_for rsync -a "${TMPDIR}/opencart-src/upload/" "${WEB_ROOT}/"

# Ensure config files exist
if [[ -f "${WEB_ROOT}/config-dist.php" && ! -f "${WEB_ROOT}/config.php" ]]; then
  need_root_for cp "${WEB_ROOT}/config-dist.php" "${WEB_ROOT}/config.php"
fi
if [[ -f "${WEB_ROOT}/admin/config-dist.php" && ! -f "${WEB_ROOT}/admin/config.php" ]]; then
  need_root_for cp "${WEB_ROOT}/admin/config-dist.php" "${WEB_ROOT}/admin/config.php"
fi

# Optional: enable .htaccess if present
if [[ -f "${WEB_ROOT}/.htaccess.txt" && ! -f "${WEB_ROOT}/.htaccess" ]]; then
  need_root_for cp "${WEB_ROOT}/.htaccess.txt" "${WEB_ROOT}/.htaccess"
fi

# -----------------------------
# 6) Permissions (secure default + writable dirs)
# -----------------------------
log "Setting permissions"
need_root_for chown -R root:www-data "${WEB_ROOT}"
need_root_for find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
need_root_for find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

# Writable directories required by OpenCart
if [[ -d "${WEB_ROOT}/system/storage" ]]; then
  need_root_for chown -R www-data:www-data "${WEB_ROOT}/system/storage"
  need_root_for find "${WEB_ROOT}/system/storage" -type d -exec chmod 775 {} \;
fi
if [[ -d "${WEB_ROOT}/image" ]]; then
  need_root_for chown -R www-data:www-data "${WEB_ROOT}/image"
  need_root_for find "${WEB_ROOT}/image" -type d -exec chmod 775 {} \;
fi

# Make config files writable for the installer
if [[ -f "${WEB_ROOT}/config.php" ]]; then
  need_root_for chown www-data:www-data "${WEB_ROOT}/config.php"
  need_root_for chmod 664 "${WEB_ROOT}/config.php"
fi
if [[ -f "${WEB_ROOT}/admin/config.php" ]]; then
  need_root_for chown www-data:www-data "${WEB_ROOT}/admin/config.php"
  need_root_for chmod 664 "${WEB_ROOT}/admin/config.php"
fi

# -----------------------------
# 7) Apache VirtualHost
# -----------------------------
log "Configuring Apache VirtualHost: ${SERVER_NAME} (alias: ${SERVER_ALIAS})"
need_root_for tee /etc/apache2/sites-available/opencart.conf >/dev/null <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    ServerAlias ${SERVER_ALIAS}

    DocumentRoot ${WEB_ROOT}/

    <Directory ${WEB_ROOT}/>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/opencart-error.log
    CustomLog \${APACHE_LOG_DIR}/opencart-access.log combined
</VirtualHost>
EOF

need_root_for a2dissite 000-default.conf >/dev/null || true
need_root_for a2ensite opencart.conf >/dev/null
need_root_for systemctl reload apache2

# -----------------------------
# 8) Basic validation
# -----------------------------
log "Validating Apache and PHP"
need_root_for apache2ctl -t

# Test local HTTP response (may be 200, 302, or installer page content)
if command_exists curl; then
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/")" || true
  log "Local HTTP status: ${HTTP_CODE}"
fi

log "OpenCart files deployed. Next step: complete the web installer."

cat <<OUT

============================================================
OpenCart is deployed.

Visit:
  http://<SERVER_IP>/

Database details (for the installer):
  DB Host: localhost
  DB Name: ${DB_NAME}
  DB User: ${DB_USER}
  DB Pass: (the value you set in DB_PASS)

IMPORTANT POST-INSTALL (run after the web installer completes):
  1) Remove the installer directory:
       sudo rm -rf "${WEB_ROOT}/install"

  2) Lock down config files again:
       sudo chown root:www-data "${WEB_ROOT}/config.php" "${WEB_ROOT}/admin/config.php"
       sudo chmod 640 "${WEB_ROOT}/config.php" "${WEB_ROOT}/admin/config.php"

============================================================
OUT
