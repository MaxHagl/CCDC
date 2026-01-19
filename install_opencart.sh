#!/bin/bash

# --- Configuration ---
DB_NAME="opencart"
DB_USER="opencart"
DB_PASS="password" # Change this to a secure password
DOMAIN="example.com"
OPENCART_VER="4.1.0.3"
OPENCART_URL="https://sourceforge.net/projects/opencart.mirror/files/${OPENCART_VER}/opencart-${OPENCART_VER}.zip/download"

# Exit immediately if a command exits with a non-zero status
set -e

echo "Starting OpenCart installation..."

# 1. Update and Install Dependencies
sudo apt update && sudo apt -y upgrade
sudo apt install -y \
  apache2 mysql-server \
  php php-fpm libapache2-mod-fcgid \
  php-mysql php-curl php-xml php-zip php-gd php-mbstring php-intl \
  unzip wget rsync

# 2. Configure Apache Modules
sudo a2enmod proxy_fcgi setenvif rewrite
sudo a2enconf php*-fpm
echo "ServerName $DOMAIN" | sudo tee /etc/apache2/conf-available/servername.conf >/dev/null
sudo a2enconf servername
sudo systemctl restart apache2

# 3. Database Setup (Automated)
echo "Configuring MySQL Database..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# 4. Download and Extract OpenCart
echo "Downloading OpenCart..."
cd /tmp
wget -O opencart.zip "$OPENCART_URL"
unzip -q opencart.zip -d opencart-src

# 5. File Deployment
sudo mkdir -p /var/www/opencart
sudo rsync -a /tmp/opencart-src/upload/ /var/www/opencart/

# Rename configuration files
sudo cp /var/www/opencart/config-dist.php /var/www/opencart/config.php
sudo cp /var/www/opencart/admin/config-dist.php /var/www/opencart/admin/config.php
sudo cp /var/www/opencart/.htaccess.txt /var/www/opencart/.htaccess

# 6. Set Permissions
echo "Setting permissions..."
sudo chown -R root:www-data /var/www/opencart
sudo find /var/www/opencart -type d -exec chmod 755 {} \;
sudo find /var/www/opencart -type f -exec chmod 644 {} \;

# Permissions for writable directories
sudo chown -R www-data:www-data /var/www/opencart/system/storage /var/www/opencart/image
sudo find /var/www/opencart/system/storage /var/www/opencart/image -type d -exec chmod 775 {} \;

# Writable config files for the installer
sudo chown www-data:www-data /var/www/opencart/config.php /var/www/opencart/admin/config.php
sudo chmod 664 /var/www/opencart/config.php /var/www/opencart/admin/config.php

# 7. Configure Apache VirtualHost
sudo tee /etc/apache2/sites-available/opencart.conf >/dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/opencart/

    <Directory /var/www/opencart/>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/opencart-error.log
    CustomLog \${APACHE_LOG_DIR}/opencart-access.log combined
</VirtualHost>
EOF

sudo a2dissite 000-default.conf
sudo a2ensite opencart.conf
sudo systemctl reload apache2

# 8. Cleanup
# Note: Usually, you should run the web installer before deleting the /install folder. 
# If you want to automate the installation fully, you'd need the CLI installer.
# sudo rm -rf /var/www/opencart/install 

echo "Setup complete! Navigate to http://$DOMAIN to finish the installation."
