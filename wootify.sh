#!/bin/bash

# ==============================================================================
# Script Quản lý WordPress trên RHEL Stack (AlmaLinux)
#
# Phiên bản: 4.5-RHEL (Tự động tạo lệnh tắt 'wpscript')
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
readonly SCRIPT_NAME="wpscript"
readonly SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
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

# --- CÁC HÀM TỰ ĐỘNG CẤU HÌNH SCRIPT ---

function create_shortcut_if_needed() {
    # Kiểm tra xem script có đang được chạy với sudo không
    if [ "$EUID" -ne 0 ]; then
        fatal_error "Vui lòng chạy script này với quyền sudo (ví dụ: sudo bash $0)"
    fi

    # Chỉ tạo shortcut nếu nó chưa tồn tại
    if [ ! -f "$SCRIPT_PATH" ]; then
        info "Tạo lệnh tắt '${SCRIPT_NAME}' để dễ dàng gọi lại menu..."
        # Copy chính file script này vào /usr/local/bin
        cp "$0" "$SCRIPT_PATH"
        # Cấp quyền thực thi
        chmod +x "$SCRIPT_PATH"
        success "Đã tạo lệnh tắt thành công. Từ lần sau, bạn chỉ cần gõ '${SCRIPT_NAME}' để mở menu."
        echo ""
    fi
}


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
    sudo dnf install -y nginx mariadb-server php php-fpm php-mysqlnd php-curl php-xml php-mbstring php-zip php-gd php-intl php-bcmath php-soap php-pecl-imagick php-exif php-opcache php-cli php-readline wget unzip policycoreutils-python-utils openssl cronie

    info "Tối ưu hóa cấu hình PHP..."
    local php_ini_path="/etc/php.ini"
    if [ -f "$php_ini_path" ]; then
        sudo sed -i 's/^;*upload_max_filesize = .*/upload_max_filesize = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*post_max_size = .*/post_max_size = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*max_execution_time = .*/max_execution_time = 1800/' "$php_ini_path"
        sudo sed -i 's/^;*max_input_time = .*/max_input_time = 1800/' "$php_ini_path"
        sudo sed -i 's/^;*memory_limit = .*/memory_limit = 1024M/' "$php_ini_path"
    fi
    
    info "Tối ưu hóa cấu hình Nginx..."
    local nginx_conf_path="/etc/nginx/nginx.conf"
    sudo sed -i 's/^\s*worker_connections\s*.*/    worker_connections 10240;/' "$nginx_conf_path"
    sudo sed -i 's/^\s*user\s*.*/user nginx;/' "$nginx_conf_path"

    if ! grep -q "client_max_body_size" "$nginx_conf_path"; then
        info "Tăng giới hạn upload file cho Nginx..."
        sudo sed -i '/http {/a \    client_max_body_size 512M;' "$nginx_conf_path"
    fi

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
    sudo systemctl enable --now nginx mariadb php-fpm crond

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
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$fpm_sock;
    }
    location ~ /\.ht { deny all; }
}
EOL

    info "Tạo FPM Pool riêng cho site..."
    local pool_conf="/etc/php-fpm.d/${domain}.conf"
    sudo tee "$pool_conf" > /dev/null <<EOL
[$domain]
user = $site_user
group = nginx
listen = $fpm_sock
listen.
