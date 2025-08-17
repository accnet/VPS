#!/bin/bash

# --- Color variables for output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting LEMP + WordPress Multisite installation process on AlmaLinux...${NC}"

# --- Require root privileges ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run with root privileges. Please run again with 'sudo'.${NC}"
   exit 1
fi

# --- Gather required information from user ---
echo -e "${YELLOW}Please provide the following information:${NC}"
read -p "  1. Your main domain name (e.g.: yourdomain.com): " MAIN_DOMAIN
read -p "  2. WordPress admin username: " WP_ADMIN_USER
read -s -p "  3. WordPress admin password: " WP_ADMIN_PASS
echo
read -p "  4. WordPress admin email address: " WP_ADMIN_EMAIL

# Generate random password for MariaDB root user
MARIADB_ROOT_PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?' | head -c 20)
echo -e "${GREEN}  Random password for MariaDB root user has been generated.${NC}"

# Generate random password for WordPress database user
DB_PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?' | head -c 16)
echo -e "${GREEN}  Random password for WordPress database user has been generated.${NC}"

# --- Update system and install tools ---
echo -e "\n${GREEN}--- Starting system update and tool installation ---${NC}"
sudo dnf update -y
sudo dnf install epel-release -y
sudo dnf install wget curl unzip policycoreutils-python-utils -y # policycoreutils-python-utils for semanage
echo -e "${GREEN}--- System update and tool installation completed ---${NC}"

# --- Install and configure Firewalld ---
echo -e "\n${GREEN}--- Starting Firewalld installation and configuration ---${NC}"
sudo dnf install firewalld -y
sudo systemctl enable firewalld
sudo systemctl start firewalld
echo -e "${GREEN}  Firewalld has been installed and started.${NC}"

# Open ports for HTTP/HTTPS (inbound)
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https

# Open ports for outbound connections so WordPress can download plugins/themes
echo -e "${YELLOW}  Configuring firewall for outbound connections so WordPress can download plugins/themes...${NC}"
sudo firewall-cmd --permanent --add-port=53/udp  # DNS
sudo firewall-cmd --permanent --add-port=80/tcp   # HTTP outbound
sudo firewall-cmd --permanent --add-port=443/tcp  # HTTPS outbound

sudo firewall-cmd --reload
echo -e "${GREEN}--- Firewalld configuration completed ---${NC}"

# --- Install Nginx ---
echo -e "\n${GREEN}--- Starting Nginx installation ---${NC}"
sudo dnf install nginx -y
sudo systemctl enable nginx
sudo systemctl start nginx
echo -e "${GREEN}--- Nginx installation completed ---${NC}"

# --- Install MariaDB ---
echo -e "\n${GREEN}--- Starting MariaDB installation ---${NC}"
sudo dnf install mariadb-server -y
sudo systemctl enable mariadb
sudo systemctl start mariadb

echo -e "${YELLOW}Setting up database and users...${NC}"

# Save MariaDB root password to ~/.my.cnf for root user
sudo tee /root/.my.cnf > /dev/null <<EOF
[client]
user=root
password="$MARIADB_ROOT_PASSWORD"
EOF
sudo chmod 600 /root/.my.cnf
echo -e "${GREEN}  MariaDB root password has been saved to /root/.my.cnf.${NC}"


# Set root password for MariaDB.
sudo mysql -u root <<MYSQL_ROOT_SETUP
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';
FLUSH PRIVILEGES;
MYSQL_ROOT_SETUP

# Create WordPress database and user
DB_NAME="wordpress_multisite"
DB_USER="wpuser"
sudo mysql -u root <<MYSQL_WP_SETUP
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_WP_SETUP

echo -e "${GREEN}--- MariaDB installation completed ---${NC}"

# --- Install PHP-FPM ---
echo -e "\n${GREEN}--- Starting PHP-FPM installation ---${NC}"
# Use PHP 8.2 as default version
# Ensure php-curl is installed for WordPress external connections
sudo dnf install @php:8.2 -y
sudo dnf install php-fpm php-mysqlnd php-gd php-xml php-mbstring php-json php-opcache php-curl php-intl php-zip php-soap php-bcmath php-gmp -y
echo -e "${GREEN}  PHP-FPM and required extensions have been installed.${NC}"

# Configure PHP-FPM to run under nginx user
sudo sed -i 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf

# Increase PHP limits (php.ini)
PHP_INI_PATH="/etc/php.ini" # Or your php.ini path if different

echo -e "${YELLOW}  Configuring PHP limits (php.ini): upload_max_filesize, post_max_size, max_execution_time, max_input_time, memory_limit...${NC}"
sudo sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 512M/' "$PHP_INI_PATH"
sudo sed -i 's/^post_max_size = .*/post_max_size = 512M/' "$PHP_INI_PATH"
sudo sed -i 's/^max_execution_time = .*/max_execution_time = 600/' "$PHP_INI_PATH" # 10 minutes = 600 seconds
sudo sed -i 's/^max_input_time = .*/max_input_time = 600/' "$PHP_INI_PATH"     # 10 minutes = 600 seconds
sudo sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI_PATH"

# Configure Opcache (usually enabled by default when php-opcache is installed, but can be optimized further)
if [ -f /etc/php.d/10-opcache.ini ]; then
    echo -e "${YELLOW}  Configuring Opcache...${NC}"
    sudo sed -i '/^;opcache.enable=/c\opcache.enable=1' /etc/php.d/10-opcache.ini
    sudo sed -i '/^;opcache.memory_consumption=/c\opcache.memory_consumption=256' /etc/php.d/10-opcache.ini # Increase Opcache memory
    sudo sed -i '/^;opcache.max_accelerated_files=/c\opcache.max_accelerated_files=20000' /etc/php.d/10-opcache.ini # Increase max files
    sudo sed -i '/^;opcache.revalidate_freq=/c\opcache.revalidate_freq=1' /etc/php.d/10-opcache.ini # Check for changes every second (production should be 0 or higher value)
    sudo sed -i '/^;opcache.fast_shutdown=/c\opcache.fast_shutdown=1' /etc/php.d/10-opcache.ini
fi

sudo systemctl enable php-fpm
sudo systemctl start php-fpm
sudo systemctl restart php-fpm # Restart to apply PHP and Opcache configuration
echo -e "${GREEN}--- PHP-FPM and extensions installation completed ---${NC}"

# --- Create self-signed SSL certificate (OpenSSL) ---
echo -e "\n${GREEN}--- Starting self-signed SSL certificate creation ---${NC}"
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
-keyout /etc/nginx/ssl/$MAIN_DOMAIN.key \
-out /etc/nginx/ssl/$MAIN_DOMAIN.crt \
-subj "/C=VN/ST=Hanoi/L=Hanoi/O=YourCompany/OU=IT/CN=$MAIN_DOMAIN"

sudo chmod 600 /etc/nginx/ssl/$MAIN_DOMAIN.key
echo -e "${GREEN}--- Self-signed SSL certificate creation completed ---${NC}"

# --- Configure Nginx for WordPress Multisite (Default Server Block) ---
echo -e "\n${GREEN}--- Configuring Nginx for WordPress Multisite ---${NC}"
NGINX_CONF_PATH="/etc/nginx/conf.d/wordpress-multisite.conf"

sudo tee $NGINX_CONF_PATH > /dev/null <<EOF
# --- WordPress Multisite Nginx Configuration with Default Server Block ---

# Block 1: HTTP to HTTPS Redirect (Default for all HTTP traffic)
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    # Redirect all HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

# Block 2: HTTPS Default Server Block for all SSL traffic
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;

    # SSL configuration (using self-signed certificate)
    ssl_certificate /etc/nginx/ssl/$MAIN_DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$MAIN_DOMAIN.key;

    # Other optimized SSL settings
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH:!SHA1:!AESCCM';
    ssl_prefer_server_ciphers on;

    # Configure Nginx to increase upload limits and timeout
    client_max_body_size 512M; # Increase Nginx upload limit
    send_timeout 600s;          # Increase Nginx send/receive data timeout
    proxy_read_timeout 600s;    # Increase timeout reading from backend (PHP-FPM) Nginx
    proxy_send_timeout 600s;    # Increase timeout sending to backend (PHP-FPM) Nginx

    # WordPress configuration
    root /var/www/wordpress;
    index index.php index.html index.htm;

    # Configuration for dotfiles (e.g. .htaccess)
    location ~ /\. {
        deny all;
    }

    # Configuration for media files (performance improvement)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
        expires max;
        log_not_found off;
        access_log off;
    }

    # Rewrite rules for WordPress Multisite
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Pass PHP scripts to PHP-FPM
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock; # PHP-FPM socket path
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
        fastcgi_read_timeout 600s; # Increase timeout reading from PHP-FPM for Nginx
    }

    # Configuration for XML-RPC (security)
    location = /xmlrpc.php {
        deny all;
        access_log off;
        log_not_found off;
    }

}
EOF

# Check Nginx configuration before reloading
sudo nginx -t
if [ $? -eq 0 ]; then
    sudo systemctl reload nginx # Only reload if configuration is correct
    echo -e "${GREEN}--- Nginx configuration has been checked and reloaded successfully ---${NC}"
else
    echo -e "${RED}--- Nginx configuration error. Please check manually. Not reloading Nginx. ---${NC}"
    exit 1
fi


# --- Download and install WordPress ---
echo -e "\n${GREEN}--- Starting WordPress installation ---${NC}"
sudo mkdir -p /var/www/wordpress
sudo chown nginx:nginx /var/www/wordpress

cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo mv wordpress/* /var/www/wordpress/

# --- Set WordPress file and directory permissions ---
echo -e "\n${GREEN}--- Setting WordPress file and directory permissions ---${NC}"
sudo chown -R nginx:nginx /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;

# Add specific permissions for uploads and wc-logs directories
echo -e "${YELLOW}  Setting write permissions for uploads and wc-logs directories...${NC}"
# Ensure uploads directory exists before changing permissions
sudo mkdir -p /var/www/wordpress/wp-content/uploads/wc-logs
sudo chown -R nginx:nginx /var/www/wordpress/wp-content/uploads/
sudo find /var/www/wordpress/wp-content/uploads/ -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress/wp-content/uploads/ -type f -exec chmod 644 {} \;
echo -e "${GREEN}--- Permission setup completed ---${NC}"

# --- Configure SELinux for WordPress ---
echo -e "\n${GREEN}--- Configuring SELinux for WordPress ---${NC}"
# Set context for WordPress directory
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/wordpress(/.*)?"
sudo restorecon -Rv /var/www/wordpress

# Set specific context for uploads directory if needed
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/wordpress/wp-content/uploads(/.*)?"
sudo restorecon -Rv /var/www/wordpress/wp-content/uploads/

# Allow Nginx to connect to PHP-FPM
sudo setsebool -P httpd_can_network_connect_php on

# Allow HTTPD to connect to general network (if still having download issues)
sudo setsebool -P httpd_can_network_connect on

echo -e "${GREEN}--- SELinux configuration completed ---${NC}"

# --- Configure Database and wp-config.php ---
echo -e "\n${GREEN}--- Configuring Database and wp-config.php ---${NC}"
# Use DB_NAME and DB_USER already defined above

# Download salts from WordPress API
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Create wp-config.php content
WP_CONFIG_CONTENT=$(cat <<EOF
<?php
define( 'DB_NAME', '$DB_NAME' );
define( 'DB_USER', '$DB_USER' );
define( 'DB_PASSWORD', '$DB_PASSWORD' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

$SALTS

\$table_prefix = 'wp_';

define( 'WP_DEBUG', false );

/* That's all, stop editing! Happy publishing. */
// --- Multisite Configuration ---
define('WP_ALLOW_MULTISITE', true);
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', true); # Always subdomain as requested
define('DOMAIN_CURRENT_SITE', '$MAIN_DOMAIN');
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);
define('COOKIE_DOMAIN', \$_SERVER['HTTP_HOST']); # Fix Multisite cookie issue

define('WP_HOME', 'https://' . DOMAIN_CURRENT_SITE);
define('WP_SITEURL', 'https://' . DOMAIN_CURRENT_SITE);

// Increase memory limit if needed (corresponds to PHP memory_limit)
define('WP_MEMORY_LIMIT', '512M'); # Increased

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';


EOF
)

# Write content to wp-config.php
echo "$WP_CONFIG_CONTENT" | sudo tee /var/www/wordpress/wp-config.php > /dev/null
echo -e "${GREEN}--- Database and wp-config.php configuration completed ---${NC}"

# --- Complete WordPress Multisite installation via WP-CLI ---
echo -e "\n${GREEN}--- Completing WordPress Multisite installation via WP-CLI ---${NC}"
# Download and install WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# Fix "wp: command not found" error by specifying full path
WP_CLI_PATH="/usr/local/bin/wp"

# Run WordPress installation (main site)
sudo -u nginx "$WP_CLI_PATH" core install \
    --url="https://$MAIN_DOMAIN" \
    --title="My WordPress Multisite" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --allow-root --path=/var/www/wordpress

# Enable Multisite at database level
sudo -u nginx "$WP_CLI_PATH" core multisite-install \
    --url="https://$MAIN_DOMAIN" \
    --title="My WordPress Multisite" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --allow-root --path=/var/www/wordpress \
    --skip-config

echo -e "${GREEN}--- WordPress Multisite installation completed ---${NC}"

echo -e "\n${YELLOW}====================================================${NC}"
echo -e "${GREEN}INSTALLATION SUCCESSFUL!${NC}"
echo -e "${YELLOW}====================================================${NC}"
echo -e "You have successfully installed LEMP + WordPress Multisite with subdomain configuration."
echo -e "Your main domain: ${GREEN}https://$MAIN_DOMAIN${NC}"
echo -e "WordPress admin user: ${GREEN}$WP_ADMIN_USER${NC}"
echo -e "WordPress admin password: ${GREEN}$WP_ADMIN_PASS${NC}"
echo -e "WordPress database password (store securely): ${GREEN}$DB_PASSWORD${NC}"
echo -e "MariaDB root password (store securely): ${GREEN}$MARIADB_ROOT_PASSWORD${NC}"
echo -e "\n${YELLOW}VERY IMPORTANT NEXT STEPS:${NC}"
echo -e "1.  Log in to your ${YELLOW}Cloudflare${NC} account."
echo -e "2.  Add ${YELLOW}$MAIN_DOMAIN${NC} to Cloudflare (if not already added)."
echo -e "3.  Update your DNS records in Cloudflare:"
echo -e "    -   Create an ${YELLOW}A${NC} record for ${YELLOW}$MAIN_DOMAIN${NC} pointing to your server IP. ${RED}ENABLE PROXY (orange cloud icon) for this record.${NC}"
echo -e "    -   Create a ${YELLOW}WILDCARD (*)${NC} ${YELLOW}A${NC} record (or CNAME) pointing to your server IP (or CNAME to ${YELLOW}$MAIN_DOMAIN${NC}). ${RED}ENABLE PROXY (orange cloud icon) for this record.${NC}"
echo -e "4.  In Cloudflare, navigate to ${YELLOW}SSL/TLS > Overview${NC} and select ${YELLOW}Full${NC} mode (DON'T select Full Strict)."
echo -e "5.  Change your domain's nameservers to Cloudflare."
echo -e "\nAfter DNS changes take effect, you can access:"
echo -e "Main website: ${GREEN}https://$MAIN_DOMAIN${NC}"
echo -e "WordPress admin panel: ${GREEN}https://$MAIN_DOMAIN/wp-admin${NC}"
echo -e "\nWhen you add new subsites (e.g.: ${YELLOW}newsite.$MAIN_DOMAIN${NC}) from the WordPress admin panel, they will automatically work and be secured by Cloudflare without additional Nginx configuration!"
echo -e "${YELLOW}====================================================${NC}"
