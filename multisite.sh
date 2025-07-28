#!/bin/bash

# --- Biến màu sắc cho output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Bắt đầu quá trình cài đặt LEMP + WordPress Multisite trên AlmaLinux...${NC}"

# --- Yêu cầu quyền root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Script này phải được chạy với quyền root. Vui lòng chạy lại với 'sudo'.${NC}"
   exit 1
fi

# --- Hỏi thông tin cần thiết từ người dùng ---
echo -e "${YELLOW}Vui lòng cung cấp các thông tin sau:${NC}"
read -p "  1. Tên miền chính của bạn (ví dụ: yourdomain.com): " MAIN_DOMAIN
read -p "  2. Tên người dùng admin cho WordPress: " WP_ADMIN_USER
read -s -p "  3. Mật khẩu admin cho WordPress: " WP_ADMIN_PASS
echo
read -p "  4. Địa chỉ email admin cho WordPress: " WP_ADMIN_EMAIL

# Tạo mật khẩu ngẫu nhiên cho người dùng root của MariaDB
MARIADB_ROOT_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>? | head -c 20)
echo -e "${GREEN}  Mật khẩu ngẫu nhiên cho người dùng root MariaDB đã được tạo.${NC}"

# Tạo mật khẩu ngẫu nhiên cho người dùng database WordPress
DB_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>? | head -c 16)
echo -e "${GREEN}  Mật khẩu ngẫu nhiên cho người dùng database WordPress đã được tạo.${NC}"

# --- Cập nhật hệ thống và cài đặt công cụ ---
echo -e "\n${GREEN}--- Bắt đầu cập nhật hệ thống và cài đặt công cụ ---${NC}"
sudo dnf update -y
sudo dnf install epel-release -y
sudo dnf install wget curl unzip policycoreutils-python-utils -y # policycoreutils-python-utils cho semanage
echo -e "${GREEN}--- Cập nhật hệ thống và cài đặt công cụ hoàn tất ---${NC}"

# --- Cài đặt và cấu hình Firewalld ---
echo -e "\n${GREEN}--- Bắt đầu cài đặt và cấu hình Firewalld ---${NC}"
sudo dnf install firewalld -y
sudo systemctl enable firewalld
sudo systemctl start firewalld
echo -e "${GREEN}  Firewalld đã được cài đặt và khởi chạy.${NC}"

# Mở cổng cho HTTP/HTTPS (inbound)
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https

# Mở cổng cho kết nối đi ra (outbound) để WordPress có thể tải plugin/theme
echo -e "${YELLOW}  Cấu hình firewall cho kết nối đi ra (outbound) để WordPress tải plugin/theme...${NC}"
sudo firewall-cmd --permanent --add-port=53/udp  # DNS
sudo firewall-cmd --permanent --add-port=80/tcp   # HTTP outbound
sudo firewall-cmd --permanent --add-port=443/tcp  # HTTPS outbound

sudo firewall-cmd --reload
echo -e "${GREEN}--- Cấu hình Firewalld hoàn tất ---${NC}"

# --- Cài đặt Nginx ---
echo -e "\n${GREEN}--- Bắt đầu cài đặt Nginx ---${NC}"
sudo dnf install nginx -y
sudo systemctl enable nginx
sudo systemctl start nginx
echo -e "${GREEN}--- Cài đặt Nginx hoàn tất ---${NC}"

# --- Cài đặt MariaDB ---
echo -e "\n${GREEN}--- Bắt đầu cài đặt MariaDB ---${NC}"
sudo dnf install mariadb-server -y
sudo systemctl enable mariadb
sudo systemctl start mariadb

echo -e "${YELLOW}Thiết lập database và người dùng...${NC}"

# Lưu mật khẩu root MariaDB vào ~/.my.cnf cho người dùng root
sudo tee /root/.my.cnf > /dev/null <<EOF
[client]
user=root
password="$MARIADB_ROOT_PASSWORD"
EOF
sudo chmod 600 /root/.my.cnf
echo -e "${GREEN}  Mật khẩu root MariaDB đã được lưu vào /root/.my.cnf.${NC}"


# Thiết lập mật khẩu root cho MariaDB.
sudo mysql -u root <<MYSQL_ROOT_SETUP
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';
FLUSH PRIVILEGES;
MYSQL_ROOT_SETUP

# Tạo database và người dùng WordPress
DB_NAME="wordpress_multisite"
DB_USER="wpuser"
sudo mysql -u root <<MYSQL_WP_SETUP
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_WP_SETUP

echo -e "${GREEN}--- Cài đặt MariaDB hoàn tất ---${NC}"

# --- Cài đặt PHP-FPM ---
echo -e "\n${GREEN}--- Bắt đầu cài đặt PHP-FPM ---${NC}"
# Sử dụng phiên bản PHP 8.2 làm mặc định
# Đảm bảo php-curl được cài đặt cho kết nối ra ngoài của WordPress
sudo dnf install @php:8.2 -y
sudo dnf install php-fpm php-mysqlnd php-gd php-xml php-mbstring php-json php-opcache php-curl php-intl php-zip php-soap php-bcmath php-gmp -y # Đã thêm php-curl
echo -e "${GREEN}  PHP-FPM và các extension cần thiết (bao gồm php-curl) đã được cài đặt.${NC}"

# Cấu hình PHP-FPM để chạy dưới user nginx
sudo sed -i 's/user = apache/user = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/group = apache/group = nginx/' /etc/php-fpm.d/www.conf

sudo systemctl enable php-fpm
sudo systemctl start php-fpm

# Cấu hình Opcache (thường đã được bật mặc định khi cài php-opcache, nhưng có thể tối ưu thêm)
# Đây là cấu hình cơ bản, bạn có thể tinh chỉnh /etc/php.d/10-opcache.ini sau này nếu cần
if [ -f /etc/php.d/10-opcache.ini ]; then
    echo -e "${YELLOW}  Cấu hình Opcache...${NC}"
    # Đảm bảo Opcache được bật
    sudo sed -i '/^;opcache.enable=/c\opcache.enable=1' /etc/php.d/10-opcache.ini
    # Cấu hình bộ nhớ cache (ví dụ 128MB)
    sudo sed -i '/^;opcache.memory_consumption=/c\opcache.memory_consumption=128' /etc/php.d/10-opcache.ini
    # Số lượng file tối đa có thể lưu cache
    sudo sed -i '/^;opcache.max_accelerated_files=/c\opcache.max_accelerated_files=10000' /etc/php.d/10-opcache.ini
    # Kiểm tra thay đổi file mỗi giây
    sudo sed -i '/^;opcache.revalidate_freq=/c\opcache.revalidate_freq=0' /etc/php.d/10-opcache.ini # 0 = kiểm tra mỗi request, tốt cho dev, production nên dùng giá trị lớn hơn
fi

sudo systemctl restart php-fpm # Khởi động lại để áp dụng cấu hình Opcache
echo -e "${GREEN}--- Cài đặt PHP-FPM và các extension hoàn tất ---${NC}"

# --- Tạo chứng chỉ SSL tự ký (OpenSSL) ---
echo -e "\n${GREEN}--- Bắt đầu tạo chứng chỉ SSL tự ký ---${NC}"
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
-keyout /etc/nginx/ssl/$MAIN_DOMAIN.key \
-out /etc/nginx/ssl/$MAIN_DOMAIN.crt \
-subj "/C=VN/ST=Hanoi/L=Hanoi/O=YourCompany/OU=IT/CN=$MAIN_DOMAIN"

sudo chmod 600 /etc/nginx/ssl/$MAIN_DOMAIN.key
echo -e "${GREEN}--- Tạo chứng chỉ SSL tự ký hoàn tất ---${NC}"

# --- Cấu hình Nginx cho WordPress Multisite (Default Server Block) ---
echo -e "\n${GREEN}--- Cấu hình Nginx cho WordPress Multisite ---${NC}"
NGINX_CONF_PATH="/etc/nginx/conf.d/wordpress-multisite.conf"

sudo tee $NGINX_CONF_PATH > /dev/null <<EOF
# --- WordPress Multisite Nginx Configuration with Default Server Block ---

# Block 1: HTTP to HTTPS Redirect (Default for all HTTP traffic)
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    # Chuyển hướng tất cả HTTP sang HTTPS
    return 301 https://\$host\$request_uri;
}

# Block 2: HTTPS Default Server Block for all SSL traffic
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;

    # Cấu hình SSL (dùng chứng chỉ tự ký)
    ssl_certificate /etc/nginx/ssl/$MAIN_DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$MAIN_DOMAIN.key;

    # Các cài đặt SSL tối ưu khác
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH:!SHA1:!AESCCM';
    ssl_prefer_server_ciphers on;

    # Cấu hình WordPress
    root /var/www/wordpress;
    index index.php index.html index.htm;

    # Cấu hình cho file dotfiles (vd: .htaccess)
    location ~ /\. {
        deny all;
    }

    # Cấu hình cho media files (tăng hiệu suất)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
        expires max;
        log_not_found off;
        access_log off;
    }

    # Rewrite rules cho WordPress Multisite
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # Pass PHP scripts to PHP-FPM
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock; # Đường dẫn socket PHP-FPM
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
    }

    # Cấu hình cho XML-RPC (bảo mật)
    location = /xmlrpc.php {
        deny all;
        access_log off;
        log_not_found off;
    }

    client_max_body_size 100M;
}
EOF

echo -e "${GREEN}--- Cấu hình Nginx hoàn tất ---${NC}"

# --- Tải và cài đặt WordPress ---
echo -e "\n${GREEN}--- Bắt đầu cài đặt WordPress ---${NC}"
sudo mkdir -p /var/www/wordpress
sudo chown nginx:nginx /var/www/wordpress

cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo mv wordpress/* /var/www/wordpress/

# --- Thiết lập quyền tệp và thư mục WordPress ---
echo -e "\n${GREEN}--- Thiết lập quyền tệp và thư mục WordPress ---${NC}"
sudo chown -R nginx:nginx /var/www/wordpress
sudo find /var/www/wordpress -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress -type f -exec chmod 644 {} \;

# Thêm quyền cho thư mục uploads và wc-logs cụ thể
echo -e "${YELLOW}  Đặt quyền ghi cho thư mục uploads và wc-logs...${NC}"
# Đảm bảo thư mục uploads tồn tại trước khi thay đổi quyền
sudo mkdir -p /var/www/wordpress/wp-content/uploads/wc-logs
sudo chown -R nginx:nginx /var/www/wordpress/wp-content/uploads/
sudo find /var/www/wordpress/wp-content/uploads/ -type d -exec chmod 755 {} \;
sudo find /var/www/wordpress/wp-content/uploads/ -type f -exec chmod 644 {} \;
echo -e "${GREEN}--- Thiết lập quyền hoàn tất ---${NC}"

# --- Cấu hình SELinux cho WordPress ---
echo -e "\n${GREEN}--- Cấu hình SELinux cho WordPress ---${NC}"
# Đặt ngữ cảnh cho thư mục WordPress
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/wordpress(/.*)?"
sudo restorecon -Rv /var/www/wordpress

# Đặt ngữ cảnh cụ thể cho thư mục uploads nếu cần
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/wordpress/wp-content/uploads(/.*)?"
sudo restorecon -Rv /var/www/wordpress/wp-content/uploads/

# Cho phép Nginx kết nối đến PHP-FPM
sudo setsebool -P httpd_can_network_connect_php on

# Cho phép HTTPD kết nối mạng chung (nếu vẫn gặp vấn đề tải xuống)
sudo setsebool -P httpd_can_network_connect on # Đã thêm dòng này

echo -e "${GREEN}--- Cấu hình SELinux hoàn tất ---${NC}"

# --- Cấu hình Database và wp-config.php ---
echo -e "\n${GREEN}--- Cấu hình Database và wp-config.php ---${NC}"
# Sử dụng DB_NAME và DB_USER đã được định nghĩa ở trên

# Tải salts từ WordPress API
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Tạo nội dung wp-config.php
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

/** Absolute path to the WordPress directory. */
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

/** Sets up WordPress vars and included files. */
require_once ABSPATH . 'wp-settings.php';

// Cấu hình Multisite
define('WP_ALLOW_MULTISITE', true);
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', true); # Luôn là subdomain theo yêu cầu
define('DOMAIN_CURRENT_SITE', '$MAIN_DOMAIN');
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);

// Fix lỗi cookie Multisite
define('COOKIE_DOMAIN', \$_SERVER['HTTP_HOST']); # Đã thêm dòng này

define('WP_HOME', 'https://' . DOMAIN_CURRENT_SITE);
define('WP_SITEURL', 'https://' . DOMAIN_CURRENT_SITE);

// Tăng giới hạn bộ nhớ nếu cần
define('WP_MEMORY_LIMIT', '256M');

EOF
)

# Ghi nội dung vào wp-config.php
echo "$WP_CONFIG_CONTENT" | sudo tee /var/www/wordpress/wp-config.php > /dev/null
echo -e "${GREEN}--- Cấu hình Database và wp-config.php hoàn tất ---${NC}"

# --- Khởi động lại Nginx và PHP-FPM ---
echo -e "\n${GREEN}--- Khởi động lại Nginx và PHP-FPM ---${NC}"
sudo systemctl restart nginx
sudo systemctl restart php-fpm
echo -e "${GREEN}--- Khởi động lại hoàn tất ---${NC}"

# --- Hoàn tất cài đặt WordPress qua WP-CLI ---
echo -e "\n${GREEN}--- Hoàn tất cài đặt WordPress Multisite qua WP-CLI ---${NC}"
# Tải và cài đặt WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# Sửa lỗi "wp: command not found" bằng cách chỉ định đường dẫn đầy đủ
WP_CLI_PATH="/usr/local/bin/wp"

# Chạy cài đặt WordPress (site chính)
sudo -u nginx "$WP_CLI_PATH" core install \
    --url="https://$MAIN_DOMAIN" \
    --title="WordPress Multisite của tôi" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --allow-root --path=/var/www/wordpress

# Kích hoạt Multisite ở cấp độ database
sudo -u nginx "$WP_CLI_PATH" core multisite-install \
    --url="https://$MAIN_DOMAIN" \
    --title="WordPress Multisite của tôi" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --allow-root --path=/var/www/wordpress \
    --skip-config

echo -e "${GREEN}--- Cài đặt WordPress Multisite hoàn tất ---${NC}"

echo -e "\n${YELLOW}====================================================${NC}"
echo -e "${GREEN}CÀI ĐẶT THÀNH CÔNG!${NC}"
echo -e "${YELLOW}====================================================${NC}"
echo -e "Bạn đã cài đặt thành công LEMP + WordPress Multisite dạng subdomain."
echo -e "Tên miền chính của bạn: ${GREEN}https://$MAIN_DOMAIN${NC}"
echo -e "Người dùng admin WordPress: ${GREEN}$WP_ADMIN_USER${NC}"
echo -e "Mật khẩu admin WordPress: ${GREEN}$WP_ADMIN_PASS${NC}"
echo -e "Mật khẩu database WordPress (lưu trữ an toàn): ${GREEN}$DB_PASSWORD${NC}"
echo -e "Mật khẩu root MariaDB (lưu trữ an toàn): ${GREEN}$MARIADB_ROOT_PASSWORD${NC}"
echo -e "\n${YELLOW}CÁC BƯỚC TIẾP THEO RẤT QUAN TRỌNG:${NC}"
echo -e "1.  Đăng nhập vào tài khoản ${YELLOW}Cloudflare${NC} của bạn."
echo -e "2.  Thêm ${YELLOW}$MAIN_DOMAIN${NC} vào Cloudflare (nếu chưa có)."
echo -e "3.  Cập nhật bản ghi DNS của bạn trong Cloudflare:"
echo -e "    -   Tạo bản ghi ${YELLOW}A${NC} cho ${YELLOW}$MAIN_DOMAIN${NC} trỏ đến IP máy chủ của bạn. ${RED}BẬT PROXY (biểu tượng đám mây cam) cho bản ghi này.${NC}"
echo -e "    -   Tạo bản ghi ${YELLOW}A${NC} (hoặc CNAME) ${YELLOW}WILDCARD (*)${NC} trỏ đến IP máy chủ của bạn (hoặc CNAME đến ${YELLOW}$MAIN_DOMAIN${NC}). ${RED}BẬT PROXY (biểu tượng đám mây cam) cho bản ghi này.${NC}"
echo -e "4.  Trong Cloudflare, điều hướng đến ${YELLOW}SSL/TLS > Overview${NC} và chọn chế độ ${YELLOW}Full${NC} (ĐỪNG chọn Full Strict)."
echo -e "5.  Chuyển Nameservers của tên miền của bạn về Cloudflare."
echo -e "\nSau khi các thay đổi DNS có hiệu lực, bạn có thể truy cập:"
echo -e "Trang web chính: ${GREEN}https://$MAIN_DOMAIN${NC}"
echo -e "Trang quản trị WordPress: ${GREEN}https://$MAIN_DOMAIN/wp-admin${NC}"
echo -e "\nKhi bạn thêm các site con mới (ví dụ: ${YELLOW}newsite.$MAIN_DOMAIN${NC}) từ trang quản trị WordPress, chúng sẽ tự động hoạt động và được bảo mật bởi Cloudflare mà không cần cấu hình Nginx thêm!"
echo -e "${YELLOW}====================================================${NC}"
