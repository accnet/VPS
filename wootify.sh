#!/bin/bash

# ==============================================================================
# Script Quản lý WordPress trên RHEL Stack (AlmaLinux)
#
# Phiên bản: 4.2-RHEL (Sửa lỗi 413 Request Entity Too Large)
#
# Các tính năng chính:
# - Cài đặt LEMP, tạo/xóa/clone/liệt kê site, cài SSL, restart dịch vụ.
# - Dùng kho EPEL & Remi, tự động quản lý firewalld.
# - Tự động cấu hình bảo mật MariaDB, tạo và lưu mật khẩu root.
# - Xử lý context SELinux tự động cho webroot và socket.
# - Tạo FPM Pool và user hệ thống riêng cho mỗi site để tăng cường bảo mật.
# ==============================================================================

# --- CÀI ĐẶT AN TOÀN ---
set -e
set -u
set -o pipefail

# --- BIẾN TOÀN CỤC VÀ HẰNG SỐ ---
readonly DEFAULT_PHP_VERSION="8.3"
readonly LEMP_INSTALLED_FLAG="/var/local/lemp_installed_rhel.flag"
readonly WP_CLI_PATH="/usr/local/bin/wp"

# Màu sắc cho giao diện
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'

# --- HÀM TIỆN ÍCH ---
info() { echo -e "${C_CYAN}INFO:${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}WARN:${C_RESET} $1"; }
menu_error() { echo -e "${C_RED}LỖI:${C_RESET} $1"; }
fatal_error() { echo -e "${C_RED}LỖI NGHIÊM TRỌNG:${C_RESET} $1"; exit 1; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }

# --- CÁC HÀM CHỨC NĂNG CHÍNH ---

function create_swap_if_needed() {
    if sudo swapon --show | grep -q '/'; then
        info "Swap đã được kích hoạt trên hệ thống. Bỏ qua."
        sudo swapon --show
        return
    fi
    warn "Không tìm thấy swap. Sẽ tiến hành tạo swap file."
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local swap_size_mb
    swap_size_mb=$((total_ram_mb * 2))
    if [ "$swap_size_mb" -gt 8192 ]; then
        warn "Dung lượng RAM lớn, giới hạn swap ở mức 8GB."
        swap_size_mb=8192
    fi
    info "Tổng RAM: ${total_ram_mb}MB. Sẽ tạo swap file dung lượng: ${swap_size_mb}MB."
    sudo fallocate -l "${swap_size_mb}M" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    success "Đã tạo và kích hoạt swap file thành công."
    sudo free -h
}

function install_lemp() {
    info "Bắt đầu quá trình cài đặt LEMP stack trên AlmaLinux..."
    create_swap_if_needed
    info "Cập nhật hệ thống..."
    sudo dnf update -y
    if sudo dnf list installed httpd &>/dev/null; then
        warn "Phát hiện httpd (Apache). Sẽ tiến hành gỡ bỏ để tránh xung đột."
        sudo systemctl stop httpd || true && sudo systemctl disable httpd || true
        sudo dnf remove httpd* -y
        success "Đã gỡ bỏ httpd thành công."
    fi
    
    info "Cài đặt kho lưu trữ EPEL và Remi..."
    sudo dnf install -y epel-release
    sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
    
    info "Kích hoạt module PHP ${DEFAULT_PHP_VERSION} từ Remi..."
    sudo dnf module reset php -y
    sudo dnf module enable "php:remi-${DEFAULT_PHP_VERSION}" -y

    info "Cài đặt Nginx, MariaDB, PHP và các extension cần thiết..."
    sudo dnf install -y nginx mariadb-server php php-fpm php-mysqlnd php-curl php-xml php-mbstring php-zip php-gd php-intl php-bcmath php-soap php-pecl-imagick php-exif php-opcache php-cli php-readline wget unzip policycoreutils-python-utils openssl

    info "Tối ưu hóa cấu hình PHP..."
    local php_ini_path="/etc/php.ini"
    if [ -f "$php_ini_path" ]; then
        sudo sed -i 's/^;*upload_max_filesize = .*/upload_max_filesize = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*post_max_size = .*/post_max_size = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*max_execution_time = .*/max_execution_time = 300/' "$php_ini_path"
        sudo sed -i 's/^;*max_input_time = .*/max_input_time = 300/' "$php_ini_path"
        sudo sed -i 's/^;*memory_limit = .*/memory_limit = 1024M/' "$php_ini_path"
    fi
    
    info "Tối ưu hóa cấu hình Nginx..."
    local nginx_conf_path="/etc/nginx/nginx.conf"
    sudo sed -i 's/^\s*worker_connections\s*.*/    worker_connections 10240;/' "$nginx_conf_path"
    sudo sed -i 's/^\s*user\s*.*/user nginx;/' "$nginx_conf_path"

    # --- SỬA LỖI 413 REQUEST ENTITY TOO LARGE ---
    if ! grep -q "client_max_body_size" "$nginx_conf_path"; then
        info "Tăng giới hạn upload file cho Nginx..."
        # Chèn vào trong khối http {}
        sudo sed -i '/http {/a \    client_max_body_size 512M;' "$nginx_conf_path"
    fi
    # --- KẾT THÚC SỬA LỖI ---


    info "Kiểm tra và cấu hình tường lửa (firewalld)..."
    if ! command -v firewall-cmd &> /dev/null; then
        warn "firewalld chưa được cài đặt. Tiến hành cài đặt..."
        sudo dnf install -y firewalld
        sudo systemctl enable --now firewalld
        success "firewalld đã được cài đặt và kích hoạt."
    else
        if ! sudo systemctl is-active --quiet firewalld; then sudo systemctl start firewalld; fi
        info "firewalld đã được cài đặt. Sẵn sàng cấu hình."
    fi
    
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload

    info "Khởi động và kích hoạt các dịch vụ chính..."
    sudo systemctl enable --now nginx mariadb php-fpm

    info "Tự động cấu hình bảo mật MariaDB..."
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
    success "MariaDB đã được cấu hình bảo mật tự động."
    warn "Mật khẩu root MariaDB đã được tạo và lưu vào /root/.my.cnf"
    echo -e "${C_YELLOW}🔑 Mật khẩu root MariaDB của bạn là:${C_RESET} ${mariadb_root_pass}"
    echo -e "${C_YELLOW}Vui lòng lưu lại mật khẩu này ở nơi an toàn!${C_RESET}"
    
    sudo touch "$LEMP_INSTALLED_FLAG"
    success "Cài đặt LEMP stack hoàn tất!"
}

function create_site() {
    info "Bắt đầu tạo site WordPress mới..."
    read -p "Nhập domain (ví dụ: mydomain.com): " domain
    if [ -z "$domain" ]; then fatal_error "Domain không được để trống."; fi
    
    local webroot="/var/www/$domain"
    local site_user="$domain"
    
    if ! id -u "$site_user" >/dev/null 2>&1; then
        info "Tạo user hệ thống '$site_user' cho site..."
        sudo useradd -r -s /sbin/nologin -d "$webroot" -g nginx "$site_user"
    else
        warn "User '$site_user' đã tồn tại. Sẽ sử dụng user này."
    fi
    
    local random_suffix
    random_suffix=$(openssl rand -hex 4)
    local safe_domain
    safe_domain=$(echo "${domain//./_}")
    
    local db_name; db_name=$(echo "${safe_domain}" | cut -c -55)_${random_suffix}
    local db_user; db_user=$(echo "${safe_domain}" | cut -c -23)_u${random_suffix}
    
    local db_pass; db_pass=$(openssl rand -base64 12)
    read -p "Nhập tên tài khoản admin WordPress (mặc định: admin): " admin_user
    read -p "Nhập email admin WordPress (mặc định: admin@$domain): " admin_email
    read -s -p "Nhập mật khẩu admin WordPress (Enter để tạo ngẫu nhiên): " admin_pass_input; echo
    local admin_user=${admin_user:-admin}
    local admin_email=${admin_email:-admin@$domain}
    local admin_pass=${admin_pass_input:-$(openssl rand -base64 10)}
    
    info "Tải và cài đặt mã nguồn WordPress..."
    sudo mkdir -p "$webroot"
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
    tar -xzf /tmp/latest.tar.gz -C /tmp && sudo cp -r /tmp/wordpress/* "$webroot" && sudo chown -R "$site_user":nginx "$webroot"
    
    info ">> SELinux: Gán context cho webroot..."
    sudo semanage fcontext -a -t httpd_sys_rw_content_t "$webroot(/.*)?"
    sudo restorecon -R "$webroot"

    info "Tạo Database và User..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS \`$db_user\`@'localhost' IDENTIFIED BY '$db_pass';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO \`$db_user\`@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    info "Tạo file cấu hình Nginx..."
    local nginx_conf="/etc/nginx/conf.d/$domain.conf"
    local fpm_sock="/var/run/php-fpm/${domain}.sock"
    sudo tee "$nginx_conf" > /dev/null <<EOL
server {
    listen 80;
    server_name $domain www.$domain;
    root $webroot;
    index index.php index.html;

    # Tăng giới hạn upload cho riêng site này nếu cần
    # client_max_body_size 512M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$fpm_sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    info "Tạo FPM Pool riêng cho site..."
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
    
    info "Kiểm tra cấu hình và reload dịch vụ..."
    if ! sudo nginx -t; then fatal_error "Cấu hình Nginx cho site $domain không hợp lệ."; fi
    sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    info "Cài đặt WordPress bằng WP-CLI..."
    if ! command -v wp &> /dev/null; then
        info "WP-CLI chưa được cài, đang tiến hành cài đặt..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar && sudo mv wp-cli.phar "$WP_CLI_PATH"
    fi
    
    sudo -u "$site_user" "$WP_CLI_PATH" core config --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" --path="$webroot" --skip-check
    sudo -u "$site_user" "$WP_CLI_PATH" core install --url="http://$domain" --title="Website $domain" --admin_user="$admin_user" --admin_password="$admin_pass" --admin_email="$admin_email" --path="$webroot"
    info "Cài đặt và kích hoạt các plugin mong muốn..."
    sudo -u "$site_user" "$WP_CLI_PATH" plugin install contact-form-7 woocommerce classic-editor wp-mail-smtp classic-widgets wp-fastest-cache code-snippets --activate --path="$webroot"
    
    info "Tạo và cấp quyền cho thư mục log của WooCommerce..."
    sudo -u "$site_user" mkdir -p "$webroot/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$webroot/wp-content"
    
    success "Tạo site http://$domain thành công!"
    echo -e "----------------------------------------"
    echo -e "📁 ${C_BLUE}Webroot:${C_RESET}       $webroot\n🛠️ ${C_BLUE}Database:${C_RESET}    $db_name\n👤 ${C_BLUE}DB User:${C_RESET}       $db_user\n🔑 ${C_BLUE}DB Password:${C_RESET} $db_pass\n👤 ${C_BLUE}WP Admin:${C_RESET}    $admin_user\n🔑 ${C_BLUE}WP Password:${C_RESET} $admin_pass"
    echo -e "----------------------------------------"

    read -p "🔐 Bạn có muốn cài SSL Let's Encrypt cho site này không? (y/N): " install_ssl_choice
    if [[ "${install_ssl_choice,,}" == "y" ]]; then
        if ! install_ssl "$domain" "$admin_email"; then
            warn "Cài đặt SSL thất bại. Website của bạn vẫn được tạo thành công tại http://$domain."
            warn "Bạn có thể thử cài lại SSL sau bằng tùy chọn 5 trong menu chính."
        fi
    fi
}

function list_sites() {
    info "Đang lấy danh sách các site..."
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    if [ ${#sites[@]} -eq 0 ]; then
        warn "Không tìm thấy site nào."
        return
    fi
    echo "📋 Danh sách các site hiện có:"
    for i in "${!sites[@]}"; do
        echo "   $((i+1)). ${sites[$i]}"
    done
}

function delete_site() {
    info "Bắt đầu quá trình xoá site WordPress."
    list_sites
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    if [ ${#sites[@]} -eq 0 ]; then return; fi
    echo "   0. 🔙 Quay lại menu chính"
    read -p "Nhập lựa chọn của bạn: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#sites[@]} ]; then menu_error "Lựa chọn không hợp lệ."; return; fi
    if [ "$choice" -eq 0 ]; then info "Đã hủy thao tác xoá."; return; fi
    local domain="${sites[$((choice-1))]}"
    
    warn "BẠN CÓ CHẮC CHẮN MUỐN XOÁ HOÀN TOÀN SITE '$domain' KHÔNG?"
    warn "Hành động này không thể hoàn tác và sẽ xóa vĩnh viễn webroot, database, user."
    read -p "Nhập tên miền '$domain' để xác nhận: " confirmation
    if [ "$confirmation" != "$domain" ]; then info "Xác nhận không khớp. Đã hủy thao tác xoá."; return; fi
    
    info "Bắt đầu xoá site '$domain'..."
    local webroot="/var/www/$domain"
    local site_user="$domain"
    
    local db_name; db_name=$(sudo -u "$site_user" "$WP_CLI_PATH" config get DB_NAME --path="$webroot" --skip-plugins --skip-themes)
    local db_user; db_user=$(sudo -u "$site_user" "$WP_CLI_PATH" config get DB_USER --path="$webroot" --skip-plugins --skip-themes)
    
    info "Xoá file cấu hình Nginx và FPM..."
    sudo rm -f "/etc/nginx/conf.d/${domain}.conf" "/etc/php-fpm.d/${domain}.conf"
    
    info "Reload dịch vụ..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    info "Xoá database và user..."
    sudo mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    sudo mysql -e "DROP USER IF EXISTS \`$db_user\`@'localhost';"
    
    info "Đảm bảo tất cả các tiến trình của user '$site_user' đã được dừng..."
    sudo pkill -u "$site_user" || true
    sleep 1

    info ">> SELinux: Xoá context của webroot..."
    sudo semanage fcontext -d "$webroot(/.*)?" || true
    
    info "Xoá user hệ thống và webroot..."
    if id -u "$site_user" >/dev/null 2>&1; then
        sudo userdel -r "$site_user"
    fi
    
    if [ -d "$webroot" ]; then
        info "Xoá tàn dư thư mục webroot..."
        sudo rm -rf "$webroot"
    fi
    
    success "Đã xoá hoàn toàn site '$domain'."
}

function clone_site() {
    info "Bắt đầu quá trình clone site WordPress."
    list_sites
    local sites_path="/etc/nginx/conf.d"
    local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
    if [ ${#sites[@]} -eq 0 ]; then return; fi
    echo "   0. 🔙 Quay lại menu chính"
    read -p "Nhập lựa chọn site nguồn: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt ${#sites[@]} ]; then menu_error "Lựa chọn không hợp lệ."; return; fi
    if [ "$choice" -eq 0 ]; then info "Đã hủy thao tác clone."; return; fi
    
    local src_domain="${sites[$((choice-1))]}"
    read -p "Nhập domain mới cho bản clone: " new_domain
    if [ -z "$new_domain" ]; then fatal_error "Domain mới không được để trống."; fi
    if [ -d "/var/www/$new_domain" ]; then fatal_error "Thư mục /var/www/$new_domain đã tồn tại."; fi
    
    info "Bắt đầu clone từ '$src_domain' sang '$new_domain'..."
    local src_webroot="/var/www/$src_domain"
    local new_webroot="/var/www/$new_domain"
    local src_site_user="$src_domain"
    local new_site_user="$new_domain"

    # Lấy thông tin DB từ site nguồn
    local src_db_name; src_db_name=$(sudo -u "$src_site_user" "$WP_CLI_PATH" config get DB_NAME --path="$src_webroot")

    # Tạo thông tin DB mới
    local random_suffix; random_suffix=$(openssl rand -hex 4)
    local new_safe_domain; new_safe_domain=$(echo "${new_domain//./_}")
    local new_db_name; new_db_name=$(echo "${new_safe_domain}" | cut -c -55)_${random_suffix}
    local new_db_user; new_db_user=$(echo "${new_safe_domain}" | cut -c -23)_u${random_suffix}
    local new_db_pass; new_db_pass=$(openssl rand -base64 12)

    info "Sao chép file..."
    sudo cp -a "$src_webroot" "$new_webroot"

    info "Tạo và cấp quyền cho user hệ thống mới..."
    if ! id -u "$new_site_user" >/dev/null 2>&1; then
        sudo useradd -r -s /sbin/nologin -d "$new_webroot" -g nginx "$new_site_user"
    fi
    sudo chown -R "$new_site_user":nginx "$new_webroot"
    
    info ">> SELinux: Gán context cho webroot mới..."
    sudo semanage fcontext -a -t httpd_sys_rw_content_t "$new_webroot(/.*)?"
    sudo restorecon -R "$new_webroot"
    
    info "Tạo và sao chép database..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$new_db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS \`$new_db_user\`@'localhost' IDENTIFIED BY '$new_db_pass';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`$new_db_name\`.* TO \`$new_db_user\`@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    sudo mysqldump "$src_db_name" | sudo mysql "$new_db_name"

    info "Cập nhật cấu hình WordPress (wp-config.php)..."
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_NAME "$new_db_name" --path="$new_webroot"
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_USER "$new_db_user" --path="$new_webroot"
    sudo -u "$new_site_user" "$WP_CLI_PATH" config set DB_PASSWORD "$new_db_pass" --path="$new_webroot"

    info "Thay thế domain trong database..."
    sudo -u "$new_site_user" "$WP_CLI_PATH" search-replace "//$src_domain" "//$new_domain" --all-tables --skip-columns=guid --path="$new_webroot"

    info "Tạo cấu hình Nginx và FPM Pool cho site mới..."
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
    
    info "Reload dịch vụ..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload php-fpm
    
    success "Clone site thành công!"
    echo -e "----------------------------------------"
    echo -e "✅ Site mới: http://$new_domain"
    echo -e "🔑 Mật khẩu DB mới: $new_db_pass"
    echo -e "----------------------------------------"
}


function install_ssl() {
    local domain=$1
    local email=$2
    info "Bắt đầu cài đặt SSL cho domain: $domain"
    sudo dnf install -y certbot python3-certbot-nginx
    
    info ">> SELinux: Cho phép Certbot kết nối mạng và sửa đổi Nginx..."
    sudo setsebool -P httpd_can_network_connect on
    
    if sudo certbot --nginx -d "$domain" -d "www.$domain" --agree-tos --no-eff-email --redirect --email "$email"; then
        info "Cập nhật URL trong WordPress để sử dụng HTTPS..."
        local webroot="/var/www/$domain"
        local site_user
        site_user=$(stat -c '%U' "$webroot")
        sudo -u "$site_user" "$WP_CLI_PATH" option update home "https://$domain" --path="$webroot"
        sudo -u "$site_user" "$WP_CLI_PATH" option update siteurl "https://$domain" --path="$webroot"
        success "Cài đặt SSL cho https://$domain thành công!"
        return 0
    else
        warn "Quá trình cài đặt SSL với Certbot đã gặp lỗi."
        return 1
    fi
}

function restart_services() {
    info "Restarting Nginx, PHP, and MariaDB...";
    sudo systemctl restart nginx php-fpm mariadb
    success "Các dịch vụ đã được restart."
}

# --- MENU CHÍNH ---
function main_menu() {
    while true; do
        clear
        echo -e "\n${C_BLUE}========= WORDPRESS MANAGER (v4.2-RHEL) =========${C_RESET}"
        echo "1. Cài đặt LEMP stack"
        echo "2. Tạo site WordPress mới"
        echo -e "${C_YELLOW}3. Xoá site WordPress${C_RESET}"
        echo "4. Clone site WordPress"
        echo "5. Cài SSL cho một site đã có"
        echo "6. Liệt kê các site"
        echo "7. Restart các dịch vụ (Nginx, PHP, DB)"
        echo -e "${C_YELLOW}0. Thoát${C_RESET}"
        echo "----------------------------------------"
        read -p "Nhập lựa chọn của bạn: " choice

        case "$choice" in
            1)
                if [ -f "$LEMP_INSTALLED_FLAG" ]; then
                    warn "LEMP stack đã được cài đặt."
                    read -p "Bạn có muốn cài đặt lại không? (y/N): " reinstall
                    if [[ "${reinstall,,}" == "y" ]]; then install_lemp; fi
                else
                    install_lemp
                fi
                ;;
            2) create_site ;;
            3) delete_site ;;
            4) clone_site ;;
            5)
                list_sites
                local sites_path="/etc/nginx/conf.d"
                local sites=($(find "$sites_path" -maxdepth 1 -type f -name "*.conf" ! -name "default.conf" -printf "%f\n" | sed 's/\.conf$//'))
                if [ ${#sites[@]} -eq 0 ]; then 
                    read -n 1 -s -r
                    continue
                fi
                read -p "Nhập domain cần cài SSL (hoặc để trống để hủy): " ssl_domain
                if [ -n "$ssl_domain" ]; then
                    if [ ! -f "/etc/nginx/conf.d/${ssl_domain}.conf" ]; then
                        menu_error "Domain '$ssl_domain' không tồn tại."
                    else
                        read -p "Nhập email của bạn: " ssl_email
                        install_ssl "$ssl_domain" "$ssl_email" || true
                    fi
                fi
                ;;
            6) list_sites ;;
            7) restart_services ;;
            0)
                info "Tạm biệt!"
                exit 0
                ;;
            *)
                menu_error "Lựa chọn không hợp lệ. Vui lòng thử lại."
                ;;
        esac
        echo -e "\n${C_CYAN}Nhấn phím bất kỳ để quay lại menu...${C_RESET}"
        read -n 1 -s -r
    done
}

# --- BẮT ĐẦU SCRIPT ---
main_menu
