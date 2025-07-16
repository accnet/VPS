#!/bin/bash

# ==============================================================================
# Script Quản lý WordPress trên LEMP Stack
#
# Phiên bản: 3.3 (Final - Sửa lỗi reload và userdel)
#
# Các tính năng chính:
# - Cài đặt LEMP, tạo/xóa/clone/liệt kê site, cài SSL, restart dịch vụ.
# - Tự động tạo swap, gỡ bỏ Apache, phát hiện Ubuntu 24+.
# - Tạo FPM Pool và user hệ thống riêng cho mỗi site để tăng cường bảo mật.
# - Tự động cài đặt danh sách plugin tùy chỉnh khi tạo site mới.
# ==============================================================================

# --- CÀI ĐẶT AN TOÀN ---
set -e
set -u
set -o pipefail

# --- BIẾN TOÀN CỤC VÀ HẰNG SỐ ---
readonly DEFAULT_PHP_VERSION="8.3"
readonly LEMP_INSTALLED_FLAG="/var/local/lemp_installed.flag"

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
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
    fi
    success "Đã tạo và kích hoạt swap file thành công."
    sudo free -h
}

function install_lemp() {
    info "Bắt đầu quá trình cài đặt LEMP stack..."
    create_swap_if_needed
    if [ -f /etc/os-release ]; then source /etc/os-release; else fatal_error "Không thể xác định phiên bản Ubuntu."; fi
    info "Đang chạy trên Ubuntu phiên bản ${VERSION_ID} (${VERSION_CODENAME:-unknown})."
    info "Cập nhật hệ thống..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    if dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "ok installed"; then
        warn "Phát hiện Apache2. Sẽ tiến hành gỡ bỏ để tránh xung đột."
        sudo systemctl stop apache2 || true && sudo systemctl disable apache2 || true
        sudo apt-get purge apache2* -y && sudo apt-get autoremove -y
        success "Đã gỡ bỏ Apache2 thành công."
    fi
    if [[ "${VERSION_CODENAME:-}" == "noble" || "${VERSION_CODENAME:-}" == "oracular" ]]; then
        warn "Phát hiện Ubuntu 24+. Sẽ sử dụng PHP ${DEFAULT_PHP_VERSION} từ kho mặc định."
    else
        info "Thêm PPA ondrej/php để có phiên bản PHP mới nhất..."
        sudo apt-get install -yq software-properties-common && sudo add-apt-repository ppa:ondrej/php -y
    fi
    sudo apt-get update
    info "Cài đặt Nginx, MariaDB và PHP ${DEFAULT_PHP_VERSION}..."
    local php_version=$DEFAULT_PHP_VERSION
    sudo apt-get install -yq nginx mariadb-server "php${php_version}" "php${php_version}-fpm" "php${php_version}-mysql" "php${php_version}-curl" "php${php_version}-xml" "php${php_version}-mbstring" "php${php_version}-zip" "php${php_version}-gd" "php${php_version}-intl" "php${php_version}-bcmath" "php${php_version}-soap" "php${php_version}-imagick" "php${php_version}-exif" "php${php_version}-opcache" "php${php_version}-cli" "php${php_version}-readline" unzip wget curl
    info "Tối ưu hóa cấu hình PHP..."
    local php_ini_path="/etc/php/${php_version}/fpm/php.ini"
    if [ -f "$php_ini_path" ]; then
        sudo sed -i 's/^;*upload_max_filesize = .*/upload_max_filesize = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*post_max_size = .*/post_max_size = 512M/' "$php_ini_path"
        sudo sed -i 's/^;*max_execution_time = .*/max_execution_time = 300/' "$php_ini_path"
        sudo sed -i 's/^;*max_input_time = .*/max_input_time = 300/' "$php_ini_path"
        sudo sed -i 's/^;*memory_limit = .*/memory_limit = 1024M/' "$php_ini_path"
        sudo sed -i 's/^;*max_input_vars = .*/max_input_vars = 5000/' "$php_ini_path"
    fi
    info "Tối ưu hóa cấu hình Nginx..."
    local nginx_conf_path="/etc/nginx/nginx.conf"
    local directives_to_manage=("sendfile" "tcp_nopush" "tcp_nodelay" "keepalive_timeout" "types_hash_max_size" "server_tokens")
    for directive in "${directives_to_manage[@]}"; do
        sudo sed -i -E "s/^(\s*${directive}\s+.*);/#\1; # Vô hiệu hóa bởi script/" "$nginx_conf_path" || true
    done
    sudo sed -i 's/^\s*worker_connections\s*.*/\tworker_connections 10240;/' "$nginx_conf_path"
    if ! grep -q "# --- MANAGED BY SCRIPT ---" "$nginx_conf_path"; then
        sudo sed -i '/http {/a \
\
# --- MANAGED BY SCRIPT ---\
    sendfile on;\
    tcp_nopush on;\
    tcp_nodelay on;\
    keepalive_timeout 65;\
    types_hash_max_size 4096;\
    server_tokens off;\
    client_max_body_size 512M;\
# --- END MANAGED BLOCK ---' "$nginx_conf_path"
    fi
    info "Kiểm tra cú pháp file cấu hình Nginx..."
    if ! sudo nginx -t; then fatal_error "Cấu hình Nginx không hợp lệ. Vui lòng kiểm tra lỗi ở trên."; fi
    success "Cấu hình Nginx hợp lệ."
    info "Khởi động và kích hoạt dịch vụ..."
    sudo systemctl restart "php${php_version}-fpm" nginx mariadb
    sudo systemctl enable nginx mariadb "php${php_version}-fpm"
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
        sudo useradd -r -s /usr/sbin/nologin -d "$webroot" -g www-data "$site_user"
    else
        warn "User '$site_user' đã tồn tại. Sẽ sử dụng user này."
    fi
    local db_name; db_name=$(echo "${domain//./_}" | cut -c -64)_db
    local db_user; db_user=$(echo "${domain//./_}" | cut -c -32)_user
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
    tar -xzf /tmp/latest.tar.gz -C /tmp && sudo cp -r /tmp/wordpress/* "$webroot" && sudo chown -R "$site_user":www-data "$webroot"
    info "Tạo Database và User..."
    sudo mariadb -e "CREATE DATABASE $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mariadb -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
    sudo mariadb -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    sudo mariadb -e "FLUSH PRIVILEGES;"
    info "Tạo file cấu hình Nginx..."
    local nginx_conf="/etc/nginx/sites-available/$domain"
    local fpm_sock="/var/run/php/${domain}.sock"
    sudo tee "$nginx_conf" > /dev/null <<EOL
server {
    listen 80;
    server_name $domain www.$domain;
    root $webroot;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:$fpm_sock; }
    location ~ /\.ht { deny all; }
}
EOL
    info "Tạo FPM Pool riêng cho site..."
    local php_version=$DEFAULT_PHP_VERSION
    local pool_conf="/etc/php/${php_version}/fpm/pool.d/${domain}.conf"
    sudo cp "/etc/php/${php_version}/fpm/pool.d/www.conf" "$pool_conf"
    sudo sed -i "s/\[www\]/\[$domain\]/" "$pool_conf"
    sudo sed -i "s|listen = /run/php/php${php_version}-fpm.sock|listen = $fpm_sock|" "$pool_conf"
    sudo sed -i "s/user = www-data/user = $site_user/" "$pool_conf"
    sudo sed -i "s/group = www-data/group = www-data/" "$pool_conf"
    sudo ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/"
    info "Kiểm tra cấu hình và reload dịch vụ..."
    if ! sudo nginx -t; then fatal_error "Cấu hình Nginx cho site $domain không hợp lệ."; fi
    sudo systemctl reload nginx && sudo systemctl reload "php${php_version}-fpm"
    info "Cài đặt WordPress bằng WP-CLI..."
    if ! command -v wp &> /dev/null; then
        info "WP-CLI chưa được cài, đang tiến hành cài đặt..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
    fi
    sudo -u "$site_user" wp core config --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" --path="$webroot" --skip-check
    sudo -u "$site_user" wp core install --url="http://$domain" --title="Website $domain" --admin_user="$admin_user" --admin_password="$admin_pass" --admin_email="$admin_email" --path="$webroot"
    info "Cài đặt và kích hoạt các plugin mong muốn..."
    sudo -u "$site_user" wp plugin install contact-form-7 woocommerce classic-editor wp-mail-smtp classic-widgets wp-fastest-cache code-snippets --activate --path="$webroot"
    info "Tạo thư mục log cho WooCommerce và cấp quyền..."
    sudo -u "$site_user" mkdir -p "$webroot/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$webroot/wp-content/uploads"
    success "Tạo site http://$domain thành công!"
    echo -e "----------------------------------------"
    echo -e "📁 ${C_BLUE}Webroot:${C_RESET}       $webroot\n🛠️ ${C_BLUE}Database:${C_RESET}    $db_name\n👤 ${C_BLUE}DB User:${C_RESET}       $db_user\n🔑 ${C_BLUE}DB Password:${C_RESET} $db_pass\n👤 ${C_BLUE}WP Admin:${C_RESET}    $admin_user\n🔑 ${C_BLUE}WP Password:${C_RESET} $admin_pass"
    echo -e "----------------------------------------"
    read -p "🔐 Bạn có muốn cài SSL Let's Encrypt cho site này không? (y/N): " install_ssl_choice
    if [[ "${install_ssl_choice,,}" == "y" ]]; then install_ssl "$domain" "$admin_email"; fi
}

function list_sites() {
    info "Đang lấy danh sách các site..."
    local sites_path="/etc/nginx/sites-available"
    local sites=($(find "$sites_path" -maxdepth 1 -type f ! -name "default" -printf "%f\n"))
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
    local sites_path="/etc/nginx/sites-available"
    local sites=($(find "$sites_path" -maxdepth 1 -type f ! -name "default" -printf "%f\n"))
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
    local webroot="/var/www/$domain"; local site_user="$domain"; local db_name; db_name=$(echo "${domain//./_}" | cut -c -64)_db; local db_user; db_user=$(echo "${domain//./_}" | cut -c -32)_user; local php_version=$DEFAULT_PHP_VERSION
    
    info "Xoá file cấu hình Nginx và FPM..."
    sudo rm -f "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/$domain" "/etc/php/${php_version}/fpm/pool.d/${domain}.conf"
    
    info "Reload dịch vụ..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload "php${php_version}-fpm"
    
    info "Xoá database và user..."
    sudo mariadb -e "DROP DATABASE IF EXISTS \`$db_name\`;" && sudo mariadb -e "DROP USER IF EXISTS '$db_user'@'localhost';" && sudo mariadb -e "FLUSH PRIVILEGES;"

    info "Đảm bảo tất cả các tiến trình của user '$site_user' đã được dừng..."
    sudo pkill -u "$site_user" || true
    sleep 1

    info "Xoá user hệ thống và webroot..."
    if id -u "$site_user" >/dev/null 2>&1; then
        sudo userdel -r "$site_user"
    fi
    
    # Xóa webroot một lần nữa để chắc chắn, phòng trường hợp userdel không xóa hết
    if [ -d "$webroot" ]; then
        info "Xoá tàn dư thư mục webroot..."
        sudo rm -rf "$webroot"
    fi
    
    success "Đã xoá hoàn toàn site '$domain'."
}

function clone_site() {
    info "Bắt đầu quá trình clone site WordPress."
    list_sites
    local sites_path="/etc/nginx/sites-available"
    local sites=($(find "$sites_path" -maxdepth 1 -type f ! -name "default" -printf "%f\n"))
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
    local src_webroot="/var/www/$src_domain"; local new_webroot="/var/www/$new_domain"; local src_db; src_db=$(echo "${src_domain//./_}" | cut -c -64)_db; local new_db; new_db=$(echo "${new_domain//./_}" | cut -c -64)_db; local new_db_user; new_db_user=$(echo "${new_domain//./_}" | cut -c -32)_user; local new_db_pass; new_db_pass=$(openssl rand -base64 12); local new_site_user="$new_domain"; local php_version=$DEFAULT_PHP_VERSION
    info "Sao chép file..." && sudo cp -a "$src_webroot" "$new_webroot"
    if ! id -u "$new_site_user" >/dev/null 2>&1; then info "Tạo user hệ thống '$new_site_user'..." && sudo useradd -r -s /usr/sbin/nologin -d "$new_webroot" -g www-data "$new_site_user"; fi
    sudo chown -R "$new_site_user":www-data "$new_webroot"
    info "Sao chép database..."
    sudo mariadb -e "CREATE DATABASE $new_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mariadb -e "CREATE USER '$new_db_user'@'localhost' IDENTIFIED BY '$new_db_pass';"
    sudo mariadb -e "GRANT ALL PRIVILEGES ON $new_db.* TO '$new_db_user'@'localhost';"
    sudo mariadb -e "FLUSH PRIVILEGES;" && sudo mysqldump "$src_db" | sudo mariadb "$new_db"
    info "Cập nhật cấu hình WordPress..."
    sudo -u "$new_site_user" wp config set DB_NAME "$new_db" --path="$new_webroot"
    sudo -u "$new_site_user" wp config set DB_USER "$new_db_user" --path="$new_webroot"
    sudo -u "$new_site_user" wp config set DB_PASSWORD "$new_db_pass" --path="$new_webroot"
    info "Thay thế domain trong database..."
    sudo -u "$new_site_user" wp search-replace "http://$src_domain" "http://$new_domain" --all-tables --skip-columns=guid --path="$new_webroot"
    sudo -u "$new_site_user" wp search-replace "https://$src_domain" "https://$new_domain" --all-tables --skip-columns=guid --path="$new_webroot"
    info "Tạo cấu hình server..."
    sudo cp "/etc/nginx/sites-available/$src_domain" "/etc/nginx/sites-available/$new_domain"
    sudo sed -i "s/$src_domain/$new_domain/g" "/etc/nginx/sites-available/$new_domain"
    sudo ln -sf "/etc/nginx/sites-available/$new_domain" "/etc/nginx/sites-enabled/"
    sudo cp "/etc/php/$php_version/fpm/pool.d/$src_domain.conf" "/etc/php/$php_version/fpm/pool.d/$new_domain.conf"
    sudo sed -i "s/\[$src_domain\]/\[$new_domain\]/g" "/etc/php/$php_version/fpm/pool.d/$new_domain.conf"
    sudo sed -i "s|/var/run/php/${src_domain}.sock|/var/run/php/${new_domain}.sock|g" "/etc/php/$php_version/fpm/pool.d/$new_domain.conf"
    sudo sed -i "s/user = $src_domain/user = $new_site_user/" "/etc/php/$php_version/fpm/pool.d/$new_domain.conf"
    info "Reload dịch vụ..."
    sudo nginx -t && sudo systemctl reload nginx && sudo systemctl reload "php${php_version}-fpm"
    success "Clone site thành công!"
    echo -e "----------------------------------------"
    echo -e "✅ Site mới: http://$new_domain"
    echo -e "🔑 DB Pass mới: $new_db_pass"
    echo -e "----------------------------------------"
}

function install_ssl() {
    local domain=$1; local email=$2; info "Cài đặt SSL cho domain: $domain"; sudo apt-get install -yq certbot python3-certbot-nginx; sudo certbot --nginx -d "$domain" -d "www.$domain" --agree-tos --no-eff-email --redirect --email "$email"; info "Cập nhật URL trong WordPress..."; local webroot="/var/www/$domain"; local site_user; site_user=$(stat -c '%U' "$webroot"); sudo -u "$site_user" wp option update home "https://$domain" --path="$webroot"; sudo -u "$site_user" wp option update siteurl "https://$domain" --path="$webroot"; success "Cài đặt SSL cho https://$domain thành công!";
}

function restart_services() {
    info "Restarting Nginx, PHP-FPM, MariaDB...";
    local php_version=$DEFAULT_PHP_VERSION
    sudo systemctl restart nginx "php${php_version}-fpm" mariadb
    success "Các dịch vụ đã được restart."
}


# --- MENU CHÍNH ---
function main_menu() {
    while true; do
        clear
        echo -e "\n${C_BLUE}========= WORDPRESS MANAGER (v3.3) =========${C_RESET}"
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
                read -p "Nhập domain cần cài SSL (hoặc để trống để hủy): " ssl_domain
                if [ -n "$ssl_domain" ]; then
                    read -p "Nhập email của bạn: " ssl_email
                    install_ssl "$ssl_domain" "$ssl_email"
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
