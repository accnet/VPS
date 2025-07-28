#!/bin/bash

# ==============================================================================
# WordPress Management Script for RHEL Stack (AlmaLinux)
#
# Version: 4.4-RHEL (Added WordPress Optimization & WP-Cron menu)
#
# Main features:
# - Install LEMP, create/delete/clone/list sites, install SSL, restart services.
# - Use EPEL & Remi repositories, automatic firewalld management.
# - Automated MariaDB security configuration, create and save root password.
# - Automatic SELinux context handling for webroot and socket.
# - Create separate FPM Pool and system user for each site to enhance security.
# ==============================================================================

# --- SAFE SETTINGS ---
set -e
set -u
set -o pipefail

# --- GLOBAL VARIABLES AND CONSTANTS ---
readonly DEFAULT_PHP_VERSION="8.3"
readonly LEMP_INSTALLED_FLAG="/var/local/lemp_installed_rhel.flag"
readonly WP_CLI_PATH="/usr/local/bin/wp"

# Colors for interface
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'

# --- UTILITY FUNCTIONS ---
info() { echo -e "${C_CYAN}INFO:${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
menu_error() { echo -e "${C_RED}ERROR:${C_RESET} $1"; }
fatal_error() { echo -e "${C_RED}FATAL ERROR:${C_RESET} $1"; exit 1; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }

# --- MAIN FUNCTIONS ---

function create_swap_if_needed() {
    if sudo swapon --show | grep -q '/'; then
        info "Swap is already enabled on the system. Skipping."
        sudo swapon --show
        return
    fi
    warn "No swap found. Creating swap file."
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local swap_size_mb
    swap_size_mb=$((total_ram_mb * 2))
    if [ "$swap_size_mb" -gt 8192 ]; then
        warn "Large RAM detected, limiting swap to 8GB."
        swap_size_mb=8192
    fi
    info "Total RAM: ${total_ram_mb}MB. Creating swap file with size: ${swap_size_mb}MB."
    sudo fallocate -l "${swap_size_mb}M" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    success "Swap file created and activated successfully."
    sudo free -h
}

function install_lemp() {
    info "Starting LEMP stack installation on AlmaLinux..."
    create_swap_if_needed
    info "Updating system..."
    sudo dnf update -y
    if sudo dnf list installed httpd &>/dev/null; then
        warn "Detected httpd (Apache). Removing to avoid conflicts."
        sudo systemctl stop httpd || true && sudo systemctl disable httpd || true
        sudo dnf remove httpd* -y
        success "Successfully removed httpd."
    fi
    
    info "Installing EPEL and Remi repositories..."
    sudo dnf install -y epel-release
    sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
    
    info "Enabling PHP ${DEFAULT_PHP_VERSION} module from Remi..."
    sudo dnf module reset php -y
    sudo dnf module enable "php:remi-${DEFAULT_PHP_VERSION}" -y

    info "Installing Nginx, MariaDB, PHP and necessary extensions..."
    sudo dnf install -y nginx mariadb-server php php-fpm php-mysqlnd php-curl php-xml php-mbstring php-zip php-gd php-intl php-bcmath php-soap php-pecl-imagick php-exif php-opcache php-cli php-readline wget unzip policycoreutils-python-utils openssl cronie

    info "Optimizing PHP configuration..."
    local php_ini_path="/etc/php.ini"
    if [ -f "$php_ini_path" ]; then
        sudo sed -i 's/^;*upload_max_filesize = .*/upload_max_filesize = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*post_max_size = .*/post_max_size = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*max_execution_time = .*/max_execution_time = 1800/' "$php_ini_path"
        sudo sed -i 's/^;*max_input_time = .*/max_input_time = 1800/' "$php_ini_path"
        sudo sed -i 's/^;*memory_limit = .*/memory_limit = 1024M/' "$php_ini_path"
    fi
    
    info "Optimizing Nginx configuration..."
    local nginx_conf_path="/etc/nginx/nginx.conf"
    sudo sed -i 's/^\s*worker_connections\s*.*/    worker_connections 10240;/' "$nginx_conf_path"
    sudo sed -i 's/^\s*user\s*.*/user nginx;/' "$nginx_conf_path"

    if ! grep -q "client_max_body_size" "$nginx_conf_path"; then
        info "Increasing file upload limit for Nginx..."
        sudo sed -i '/http {/a \    client_max_body_size 512M;' "$nginx_conf_path"
    fi

    info "Checking and configuring firewall (firewalld)..."
    if ! command -v firewall-cmd &> /dev/null; then
        warn "firewalld not installed. Installing..."
        sudo dnf install -y firewalld
        sudo systemctl enable --now firewalld
        success "firewalld has been installed and activated."
    else
        if ! sudo systemctl is-active --quiet firewalld; then sudo systemctl start firewalld; fi
        info "firewalld is already installed. Ready for configuration."
    fi
    
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload

    info "Starting and enabling main services..."
    sudo systemctl enable --now nginx mariadb php-fpm crond

    info "Automatically configuring MariaDB security..."
    local mariadb_root_pass
    mariadb_root_pass=$(openssl rand -base64 16)

    sudo mysql -u root -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$mariadb_root_pass'); FLUSH PRIVILEGES;"

    sudo tee /root/.my.cnf > /dev/null <<EOL
[client]
user=root
password="$mariadb_root_pass"
EOL
    sudo chmod 600 /root/.my.cnf

    sudo mysql -u root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    success "MariaDB has been automatically secured."
    warn "MariaDB root password has been created and saved to /root/.my.cnf"
    echo -e "${C_YELLOW}🔑 Your MariaDB root password is:${C_RESET} ${mariadb_root_pass}"
    echo -e "${C_YELLOW}Please save this password in a safe place!${C_RESET}"
    
    sudo touch "$LEMP_INSTALLED_FLAG"
    success "LEMP stack installation completed!"
}

function create_site() {
    info "Starting creation of new WordPress site..."
    read -p "Enter domain (example: mydomain.com): " domain
    if [ -z "$domain" ]; then fatal_error "Domain cannot be empty."; fi
    
    local webroot="/var/www/$domain"
    local site_user="$domain"
    
    if ! id -u "$site_user" >/dev/null 2>&1; then
        info "Creating system user '$site_user' for site..."
        sudo useradd -r -s /sbin/nologin -d "$webroot" -g nginx "$site_user"
    else
        warn "User '$site_user' already exists. Will use this user."
    fi
    
    local random_suffix
    random_suffix=$(openssl rand -hex 4)
    local safe_domain
    safe_domain=$(echo "${domain//./_}")
    
    local db_name; db_name=$(echo "${safe_domain}" | cut -c -55)_${random_suffix}
    local db_user; db_user=$(echo "${safe_domain}" | cut -c -23)_u${random_suffix}
    
    local db_pass; db_pass=$(openssl rand -base64 12)
    read -p "Enter WordPress admin username (default: admin): " admin_user
    read -p "Enter WordPress admin email (default: admin@$domain): " admin_email
    read -s -p "Enter WordPress admin password (Press Enter to generate random): " admin_pass_input; echo
    local admin_user=${admin_user:-admin}
    local admin_email=${admin_email:-admin@$domain}
    local admin_pass=${admin_pass_input:-$(openssl rand -base64 10)}
    
    info "Downloading and installing WordPress..."
    sudo mkdir -p "$webroot"
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
    tar -xzf /tmp/latest.tar.gz -C /tmp && sudo cp -r /tmp/wordpress/* "$webroot" && sudo chown -R "$site_user":nginx "$webroot"
    
    info ">> SELinux: Setting context for webroot..."
    sudo semanage fcontext -a -t httpd_sys_rw_content_t "$webroot(/.*)?"
    sudo restorecon -R "$webroot"

    info "Creating Database and User..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS \`$db_user\`@'localhost' IDENTIFIED BY '$db_pass';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO \`$db_user\`@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    info "Creating Nginx configuration file..."
    local nginx_conf="/etc/nginx/conf.d/$domain.conf"
    local fpm_sock="/var/run/php-fpm/${domain}.sock"
    sudo tee "$nginx_conf" > /dev/null <<EOL
server {
    listen 80;
    server_name $domain www.$domain;
    root $webroot;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$fpm_sock;
    }
    location ~ /\.ht { deny all; }
}
EOL

    info "Creating dedicated FPM Pool for site..."
    local pool_conf="/etc/php-fpm.d/${domain}.conf"
    sudo tee "$pool_conf" > /dev/null <<EOL
[$domain]
user = $site_user
group = nginx
listen = $fpm_sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
pm.max_requests = 500
EOL
    
    info "Checking configuration and reloading services..."
    if ! sudo nginx -t; then fatal_error "Nginx configuration for site $domain is invalid."; fi
    sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    info "Installing WordPress with WP-CLI..."
    if ! command -v wp &> /dev/null; then
        info "WP-CLI not installed, installing now..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar && sudo mv wp-cli.phar "$WP_CLI_PATH"
    fi
    
    sudo -u "$site_user" "$WP_CLI_PATH" core config --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" --path="$webroot" --skip-check
    sudo -u "$site_user" "$WP_CLI_PATH" core install --url="http://$domain" --title="Website $domain" --admin_user="$admin_user" --admin_password="$admin_pass" --admin_email="$admin_email" --path="$webroot"
    info "Installing and activating desired plugins..."
    sudo -u "$site_user" "$WP_CLI_PATH" plugin install contact-form-7 woocommerce classic-editor wp-mail-smtp classic-widgets wp-fastest-cache code-snippets --activate --path="$webroot"
    
    info "Creating and setting permissions for WooCommerce log directory..."
    sudo -u "$site_user" mkdir -p "$webroot/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$webroot/wp-content"
    
    success "Site http://$domain created successfully!"
    echo -e "----------------------------------------"
    echo -e "📁 ${C_BLUE}Webroot:${C_RESET}       $webroot\n🛠️ ${C_BLUE}Database:${C_RESET}    $db_name\n👤 ${C_BLUE}DB User:${C_RESET}       $db_user\n🔑 ${C_BLUE}DB Password:${C_RESET} $db_pass\n👤 ${C_BLUE}WP Admin:${C_RESET}    $admin_user\n🔑 ${C_BLUE}WP Password:${C_RESET} $admin_pass"
    echo -e "----------------------------------------"

    read -p "🔐 Do you want to install Let's Encrypt SSL for this site? (y/N): " install_ssl_choice
    if [[ "${install_ssl_choice,,}" == "y" ]]; then
        if ! install_ssl "$domain" "$admin_email"; then
            warn "SSL installation failed. Your website was still created successfully at http://$domain."
            warn "You can try installing SSL later using option 5 in the main menu."
        fi
    fi
}

function list_sites() {
    info "Retrieving list of sites..."
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    if [ ${#sites[@]} -eq 0 ]; then
        warn "No sites found."
        return 1
    fi
    echo "📋 List of existing sites:"
    for i in "${!sites[@]}"; do
        echo "   $((i+1)). ${sites[$i]}"
    done
    return 0
}

function delete_site() {
    info "Starting WordPress site deletion process."
    list_sites || return
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    echo "   0. 🔙 Back to main menu"
    read -p "Enter your choice: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#sites[@]} ]; then menu_error "Invalid choice."; return; fi
    if [ "$choice" -eq 0 ]; then info "Deletion cancelled."; return; fi
    local domain="${sites[$((choice-1))]}"
    
    warn "ARE YOU SURE YOU WANT TO COMPLETELY DELETE SITE '$domain'?"
    warn "This action is irreversible and will permanently delete the webroot, database, and user."
    read -p "Type the domain name '$domain' to confirm: " confirmation
    if [ "$confirmation" != "$domain" ]; then info "Confirmation mismatch. Deletion cancelled."; return; fi
    
    info "Starting deletion of site '$domain'..."
    local webroot="/var/www/$domain"
    local site_user="$domain"
    
    local db_name; db_name=$(sudo -u "$site_user" "$WP_CLI_PATH" config get DB_NAME --path="$webroot" --skip-plugins --skip-themes)
    local db_user; db_user=$(sudo -u "$site_user" "$WP_CLI_PATH" config get DB_USER --path="$webroot" --skip-plugins --skip-themes)
    
    info "Deleting Nginx, FPM, and Cron configuration files..."
    sudo rm -f "/etc/nginx/conf.d/${domain}.conf" "/etc/php-fpm.d/${domain}.conf" "/etc/cron.d/wp-cron-${domain}"
    
    info "Reloading services..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    info "Deleting database and user..."
    sudo mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    sudo mysql -e "DROP USER IF EXISTS \`$db_user\`@'localhost';"
    
    info "Ensuring all processes for user '$site_user' are stopped..."
    sudo pkill -u "$site_user" || true
    sleep 1

    info ">> SELinux: Removing webroot context..."
    sudo semanage fcontext -d "$webroot(/.*)?" || true
    
    info "Deleting system user and webroot..."
    if id -u "$site_user" >/dev/null 2>&1; then
        sudo userdel -r "$site_user"
    fi
    
    if [ -d "$webroot" ]; then
        info "Deleting residual webroot directory..."
        sudo rm -rf "$webroot"
    fi
    
    success "Site '$domain' completely deleted."
}

function clone_site() {
    info "Starting WordPress site cloning process."
    list_sites || return
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    echo "   0. 🔙 Back to main menu"
    read -p "Enter source site choice: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#sites[@]} ]; then menu_error "Invalid choice."; return; fi
    if [ "$choice" -eq 0 ]; then info "Cloning cancelled."; return; fi
    
    local src_domain="${sites[$((choice-1))]}"
    read -p "Enter new domain for the clone: " new_domain
    if [ -z "$new_domain" ]; then fatal_error "New domain cannot be empty."; fi
    if [ -d "/var/www/$new_domain" ]; then fatal_error "Directory /var/www/$new_domain already exists."; fi
    
    info "Starting clone from '$src_domain' to '$new_domain'..."
    local src_webroot="/var/www/$src_domain"
    local new_webroot="/var/www/$new_domain"
    local src_site_user="$src_domain"
    local new_site_user="$new_domain"

    local src_db_name; src_db_name=$(sudo -u "$src_site_user" "$WP_CLI_PATH" config get DB_NAME --path="$src_webroot")

    local random_suffix; random_suffix=$(openssl rand -hex 4)
    local new_safe_domain; new_safe_domain=$(echo "${new_domain//./_}")
    local new_db_name; new_db_name=$(echo "${new_safe_domain}" | cut -c -55)_${random_suffix}
    local new_db_user; new_db_user=$(echo "${new_safe_domain}" | cut -c -23)_u${random_suffix}
    local new_db_pass; new_db_pass=$(openssl rand -base64 12)

    info "Copying files..."
    sudo cp -a "$src_webroot" "$new_webroot"

    info "Creating and setting permissions for new system user..."
    if ! id -u "$new_site_user" >/dev/null 2>&1; then
        sudo useradd -r -s /sbin/nologin -d "$new_webroot" -g nginx "$new_site_user"
    fi
    sudo chown -R "$new_site_user":nginx "$new_webroot"
    
    info ">> SELinux: Assigning context for new webroot..."
    sudo semanage fcontext -a -t httpd_sys_rw_content_t "$new_webroot(/.*)?"
    sudo restorecon -R "$new_webroot"
    
    info "Creating and copying database..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$new_db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS \`$new_db_user\`@'localhost' IDENTIFIED BY '$new_db_pass';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`$new_db_name\`.* TO \`$new_db_user\`@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    sudo mysqldump "$src_db_name" | sudo mysql "$new_db_name"

    info "Updating WordPress configuration (wp-config.php)..."
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_NAME "$new_db_name" --path="$new_webroot"
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_USER "$new_db_user" --path="$new_webroot"
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_PASSWORD "$new_db_pass" --path="$new_webroot"

    info "Replacing domain in database..."
    sudo -u "$new_site_user" "$WP_CLI_PATH" search-replace "//$src_domain" "//$new_domain" --all-tables --skip-columns=guid --path="$new_webroot"

    info "Creating Nginx configuration and FPM Pool for new site..."
    local new_nginx_conf="/etc/nginx/conf.d/$new_domain.conf"
    local new_fpm_sock="/var/run/php-fpm/${new_domain}.sock"
    sudo cp "/etc/nginx/conf.d/$src_domain.conf" "$new_nginx_conf"
    sudo sed -i "s/$src_domain/$new_domain/g" "$new_nginx_conf"
    sudo sed -i "s|/var/run/php-fpm/${src_domain}.sock|${new_fpm_sock}|" "$new_nginx_conf"
    
    local new_pool_conf="/etc/php-fpm.d/${new_domain}.conf"
    sudo cp "/etc/php-fpm.d/$src_domain.conf" "$new_pool_conf"
    sudo sed -i "s/\[$src_domain\]/\[$new_domain\]/" "$new_pool_conf"
    sudo sed -i "s/user = $src_site_user/user = $new_site_user/" "$new_pool_conf"
    sudo sed -i "s|listen = /var/run/php-fpm/${src_domain}.sock|listen = ${new_fpm_sock}|" "$new_pool_conf"
    
    info "Reloading services..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    success "Site cloned successfully!"
    echo -e "----------------------------------------"
    echo -e "✅ New site: http://$new_domain"
    echo -e "🔑 New DB Password: $new_db_pass"
    echo -e "----------------------------------------"
}

function install_ssl() {
    local domain=$1
    local email=$2
    info "Starting SSL installation for domain: $domain"
    sudo dnf install -y certbot python3-certbot-nginx
    
    info ">> SELinux: Allowing Certbot network connection and Nginx modification..."
    sudo setsebool -P httpd_can_network_connect on
    
    if sudo certbot --nginx -d "$domain" -d "www.$domain" --agree-tos --no-eff-email --redirect --email "$email"; then
        info "Updating URL in WordPress to use HTTPS..."
        local webroot="/var/www/$domain"
        local site_user
        site_user=$(stat -c '%U' "$webroot")
        sudo -u "$site_user" "$WP_CLI_PATH" option update home "https://$domain" --path="$webroot"
        sudo -u "$site_user" "$WP_CLI_PATH" option update siteurl "https://$domain" --path="$webroot"
        success "SSL installation for https://$domain successful!"
        return 0
    else
        warn "SSL installation process with Certbot failed."
        return 1
    fi
}

# --- OPTIMIZATION MENU ---
function optimize_wp_cron() {
    info "Optimizing WP-Cron by using a system cron job."
    list_sites || return
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    echo "   0. 🔙 Back to menu"
    read -p "Select site to optimize WP-Cron: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#sites[@]} ]; then menu_error "Invalid choice."; return; fi
    if [ "$choice" -eq 0 ]; then info "Operation cancelled."; return; fi
    
    local domain="${sites[$((choice-1))]}"
    local webroot="/var/www/$domain"
    local site_user="$domain"
    local config_file="$webroot/wp-config.php"
    local cron_file="/etc/cron.d/wp-cron-$domain"

    info "Disabling default WP-Cron in wp-config.php..."
    if grep -q "DISABLE_WP_CRON" "$config_file"; then
        warn "WP-Cron is already disabled in wp-config.php."
    else
        sudo sed -i "/\/\* That's all, stop editing!/i define('DISABLE_WP_CRON', true);" "$config_file"
        success "Added define('DISABLE_WP_CRON', true); to $config_file."
    fi

    info "Creating system cron job..."
    if [ -f "$cron_file" ]; then
        warn "Cron job for domain '$domain' already exists at $cron_file."
        echo "Current content:"
        sudo cat "$cron_file"
    else
        local site_url
        site_url=$(sudo -u "$site_user" "$WP_CLI_PATH" option get siteurl --path="$webroot")
        local cron_command="*/5 * * * * nginx wget -q -O - ${site_url}/wp-cron.php?doing_wp_cron >/dev/null 2>&1"
        echo "$cron_command" | sudo tee "$cron_file" > /dev/null
        sudo chmod 644 "$cron_file"
        success "Cron job created at $cron_file, runs every 5 minutes."
    fi
}

function optimize_menu() {
    while true; do
        clear
        echo -e "\n${C_BLUE}========= WORDPRESS OPTIMIZATION MENU =========${C_RESET}"
        echo "1. Optimize WP-Cron (Separate from user tasks)"
        echo "0. 🔙 Back to main menu"
        echo "----------------------------------------"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) optimize_wp_cron ;;
            0) return ;;
            *) menu_error "Invalid choice." ;;
        esac
        echo -e "\n${C_CYAN}Press any key to return...${C_RESET}"
        read -n 1 -s -r
    done
}

function restart_services() {
    info "Restarting Nginx, PHP, and MariaDB...";
    sudo systemctl restart nginx php-fpm mariadb
    success "Services have been restarted."
}

# --- MAIN MENU ---
function main_menu() {
    while true; do
        clear
        echo -e "\n${C_BLUE}========= WORDPRESS MANAGER (v4.4-RHEL) =========${C_RESET}"
        echo "1. Install LEMP stack"
        echo "2. Create new WordPress site"
        echo "3. Clone WordPress site"
        echo "4. Install SSL for an existing site"
        echo "5. List sites"
        echo "6. Restart services (Nginx, PHP, DB)"
        echo "7. ${C_CYAN}Optimize WordPress${C_RESET}"
        echo -e "${C_YELLOW}8. Delete WordPress site${C_RESET}"
        echo -e "${C_YELLOW}0. Exit${C_RESET}"
        echo "----------------------------------------"
        read -p "Enter your choice: " choice

        case "$choice" in
            1) install_lemp ;;
            2) create_site ;;
            3) clone_site ;;
            4)
                list_sites || continue
                read -p "Enter domain for SSL installation (or leave blank to cancel): " ssl_domain
                if [ -n "$ssl_domain" ]; then
                    if [ ! -f "/etc/nginx/conf.d/${ssl_domain}.conf" ]; then
                        menu_error "Domain '$ssl_domain' does not exist."
                    else
                        read -p "Enter your email: " ssl_email
                        install_ssl "$ssl_domain" "$ssl_email" || true
                    fi
                fi
                ;;
            5) list_sites ;;
            6) restart_services ;;
            7) optimize_menu ;;
            8) delete_site ;;
            0)
                info "Goodbye!"
                exit 0
                ;;
            *)
                menu_error "Invalid choice. Please try again."
                ;;
        esac
        echo -e "\n${C_CYAN}Press any key to return to the main menu...${C_RESET}"
        read -n 1 -s -r
    done
}

# --- START SCRIPT ---
main_menu
