#!/usr/bin/env bash
# File: wordpress-install.sh
# Location: /install/wordpress-install.sh (on Proxmox host)
# Purpose: Installation script that runs within the LXC container

# Copyright (c) 2021-2025 koncept-kit
# License: MIT | https://github.com/koncept-kit/ProxmoxVE/raw/main/LICENSE
# Description: WordPress LXC installation with HTTPS and PHPMyAdmin

# Exit script if command fails
set -e

# Display time during script execution
export DEBIAN_FRONTEND=noninteractive

# Prevent locale package installation or upgrades
echo 'locales hold' | dpkg --set-selections
echo 'libc-bin hold' | dpkg --set-selections
echo 'libc-l10n hold' | dpkg --set-selections

# Define variables
WORDPRESS_DB_NAME="wordpress"
WORDPRESS_DB_USER="wpuser"
# Generate random passwords
WORDPRESS_DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
MARIADB_ROOT_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

# Save passwords
echo "${WORDPRESS_DB_PASS}" > /root/.wp_db_pass
echo "${MARIADB_ROOT_PASS}" > /root/.mariadb_root_password
chmod 600 /root/.wp_db_pass /root/.mariadb_root_password

# Install dependencies and required packages minimally
apt-get update
apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg software-properties-common

# Step 1: Install Apache web server and enable required modules
echo "Installing Apache web server..."
apt-get install -y --no-install-recommends apache2
a2enmod ssl
a2enmod rewrite
a2enmod headers
systemctl restart apache2

# Step 2: Install MariaDB with proper initialization
echo "Installing MariaDB database server..."
apt-get install -y --no-install-recommends mariadb-server

# Make sure MariaDB is running
systemctl start mariadb
systemctl enable mariadb

# Initialize MariaDB root password directly
echo "Setting MariaDB root password..."
mysqladmin -u root password "${MARIADB_ROOT_PASS}" 2>/dev/null || echo "Root password may already be set, continuing..."

# Use root password for further operations with better error handling
echo "Configuring MariaDB security settings..."
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Step 3: Install PHP and required extensions for WordPress
echo "Installing PHP and extensions..."
apt-get install -y --no-install-recommends php php-mysql php-zip php-gd \
  php-mbstring php-curl php-xml

# Step 4: Configure PHP for WordPress
echo "Configuring PHP for optimal WordPress performance..."
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
PHP_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"

# Update PHP settings
sed -i 's/memory_limit = .*/memory_limit = 256M/' "${PHP_INI}"
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' "${PHP_INI}"
sed -i 's/post_max_size = .*/post_max_size = 64M/' "${PHP_INI}"
sed -i 's/max_execution_time = .*/max_execution_time = 300/' "${PHP_INI}"
sed -i 's/max_input_time = .*/max_input_time = 300/' "${PHP_INI}"

# Step 5: Install PHPMyAdmin
echo "Installing PHPMyAdmin..."
apt-get install -y --no-install-recommends phpmyadmin
# Create symbolic link for PHPMyAdmin
ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin

# Step 6: Create WordPress database
echo "Creating WordPress database..."
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS ${WORDPRESS_DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

# Create user with simpler syntax that works in older MariaDB versions
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON ${WORDPRESS_DB_NAME}.* TO '${WORDPRESS_DB_USER}'@'localhost' IDENTIFIED BY '${WORDPRESS_DB_PASS}';" 2>/dev/null || true
mysql -u root -p"${MARIADB_ROOT_PASS}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Step 7: Download and configure WordPress
echo "Downloading WordPress..."
cd /var/www/html

# Remove default Apache index.html file
rm -f index.html

# Download and extract WordPress
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
rm latest.tar.gz

# Move WordPress files to root directory instead of subdirectory
mv wordpress/* .
rmdir wordpress

# Create wp-config.php
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
sed -i "s/database_name_here/${WORDPRESS_DB_NAME}/" /var/www/html/wp-config.php
sed -i "s/username_here/${WORDPRESS_DB_USER}/" /var/www/html/wp-config.php
sed -i "s/password_here/${WORDPRESS_DB_PASS}/" /var/www/html/wp-config.php

# Set WordPress salts
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
sed -i "/define('AUTH_KEY'/d" /var/www/html/wp-config.php
sed -i "/define('SECURE_AUTH_KEY'/d" /var/www/html/wp-config.php
sed -i "/define('LOGGED_IN_KEY'/d" /var/www/html/wp-config.php
sed -i "/define('NONCE_KEY'/d" /var/www/html/wp-config.php
sed -i "/define('AUTH_SALT'/d" /var/www/html/wp-config.php
sed -i "/define('SECURE_AUTH_SALT'/d" /var/www/html/wp-config.php
sed -i "/define('LOGGED_IN_SALT'/d" /var/www/html/wp-config.php
sed -i "/define('NONCE_SALT'/d" /var/www/html/wp-config.php
PHP_SALTS=$(echo "${SALTS}" | sed -e "s/')/');/g")
printf '%s\n' "${PHP_SALTS}" >> /var/www/html/wp-config.php

# Add this to make WordPress work behind SSL
cat >> /var/www/html/wp-config.php << 'EOF'

/* SSL Settings */
define('FORCE_SSL_ADMIN', true);

/* Fix WordPress URLs when behind HTTPS proxy */
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https')
    $_SERVER['HTTPS'] = 'on';

EOF

# Step 8: Set correct permissions for WordPress
echo "Setting correct permissions..."
chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# Step 9: Generate SSL certificate
echo "Generating self-signed SSL certificate..."
mkdir -p /etc/apache2/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/apache2/ssl/apache.key \
    -out /etc/apache2/ssl/apache.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=wordpress.local"

# Step 10: Configure Apache VirtualHost for WordPress with SSL
echo "Configuring Apache for WordPress with SSL..."

# First completely disable the default site
a2dissite 000-default
a2dissite default-ssl
rm -f /etc/apache2/sites-enabled/000-default.conf
rm -f /etc/apache2/sites-enabled/default-ssl.conf

# Create the WordPress site configuration with high priority 
cat > /etc/apache2/sites-available/001-wordpress-ssl.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/wordpress_error.log
    CustomLog \${APACHE_LOG_DIR}/wordpress_access.log combined
    
    # Redirect all HTTP traffic to HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

<VirtualHost *:443>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/wordpress_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/wordpress_ssl_access.log combined
    
    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/apache.crt
    SSLCertificateKeyFile /etc/apache2/ssl/apache.key
    
    <FilesMatch "\.(cgi|shtml|phtml|php)$">
        SSLOptions +StdEnvVars
    </FilesMatch>
    
    BrowserMatch "MSIE [2-6]" nokeepalive ssl-unclean-shutdown downgrade-1.0 force-response-1.0
    BrowserMatch "MSIE [17-9]" ssl-unclean-shutdown
</VirtualHost>
EOF

# Explicitly set this as the default site
ln -sf /etc/apache2/sites-available/001-wordpress-ssl.conf /etc/apache2/sites-enabled/001-wordpress-ssl.conf

# Create a minimal index.html to test if Apache is working at all
echo "<html><body><h1>Redirecting to WordPress...</h1><script>window.location.href='/';</script></body></html>" > /var/www/html/index.html.bak

# Ensure the main index.php is there and working
echo "<?php
// Silence is golden.
include('./index.php');
?>" > /var/www/html/index.html

# Restart Apache to apply all settings
systemctl restart apache2

# Step 11: Create an auto-regenerate SSL script for cloning
echo "Creating automatic SSL regeneration script..."
cat > /usr/local/bin/regenerate-ssl.sh << 'EOF'
#!/bin/bash

# Get current hostname or IP
CURRENT_HOST=$(hostname -f 2>/dev/null || hostname)

# Check if certificate needs to be regenerated
CERT_HOST=$(openssl x509 -noout -subject -in /etc/apache2/ssl/apache.crt 2>/dev/null | grep -o 'CN = [^ ,]*' | cut -d '=' -f2 | tr -d ' ')

if [ "$CERT_HOST" != "$CURRENT_HOST" ]; then
  echo "Regenerating SSL certificate for $CURRENT_HOST..."
  
  # Generate new self-signed certificate
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/apache2/ssl/apache.key \
    -out /etc/apache2/ssl/apache.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$CURRENT_HOST"
  
  # Restart Apache to apply new certificate
  systemctl restart apache2
  
  echo "SSL certificate regenerated successfully."
fi

# Also regenerate WordPress salts for better security on cloned instances
if [ ! -f /root/.wp_salts_updated ]; then
  echo "Regenerating WordPress salts..."
  
  SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
  PHP_SALTS=$(echo "${SALTS}" | sed -e "s/')/');/g")
  
  # Remove existing salts
  sed -i "/define('AUTH_KEY'/d" /var/www/html/wp-config.php
  sed -i "/define('SECURE_AUTH_KEY'/d" /var/www/html/wp-config.php
  sed -i "/define('LOGGED_IN_KEY'/d" /var/www/html/wp-config.php
  sed -i "/define('NONCE_KEY'/d" /var/www/html/wp-config.php
  sed -i "/define('AUTH_SALT'/d" /var/www/html/wp-config.php
  sed -i "/define('SECURE_AUTH_SALT'/d" /var/www/html/wp-config.php
  sed -i "/define('LOGGED_IN_SALT'/d" /var/www/html/wp-config.php
  sed -i "/define('NONCE_SALT'/d" /var/www/html/wp-config.php
  
  # Add new salts
  printf '%s\n' "${PHP_SALTS}" >> /var/www/html/wp-config.php
  
  # Create flag file to indicate salts have been updated
  touch /root/.wp_salts_updated
  
  echo "WordPress salts regenerated successfully."
fi
EOF

# Make the script executable
chmod +x /usr/local/bin/regenerate-ssl.sh

# Configure script to run at boot time
cat > /etc/systemd/system/regenerate-ssl.service << 'EOF'
[Unit]
Description=Regenerate SSL Certificate If Needed
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/regenerate-ssl.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl enable regenerate-ssl.service

# Step 12: Final cleanup for templating
echo "Performing final cleanup for templating..."
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
rm -f /root/.wp_salts_updated  # Remove this flag to ensure salts are regenerated on clone

echo "WordPress installation complete!"
echo "WordPress URL: https://your-server-ip/"
echo "PHPMyAdmin URL: https://your-server-ip/phpmyadmin/"
echo "WordPress database name: ${WORDPRESS_DB_NAME}"
echo "WordPress database user: ${WORDPRESS_DB_USER}"
echo "WordPress database password: Saved to /root/.wp_db_pass"
echo "MariaDB root password: Saved to /root/.mariadb_root_password"