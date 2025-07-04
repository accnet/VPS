#!/bin/bash

LEMP_INSTALLED_FLAG="/var/local/lemp_installed.flag"
PHP_VERSION="8.2"

# Function to install SSL via Let's Encrypt
function install_ssl() {
    DOMAIN=$1
    echo "🔒 Cài đặt SSL cho $DOMAIN..."

    # Cài đặt Certbot (Let's Encrypt)
    sudo dnf install -y certbot python3-certbot-nginx

    # Cài đặt SSL cho domain
    sudo certbot --nginx -d $DOMAIN --agree-tos --no-eff-email --email admin@$DOMAIN

    # Tự động gia hạn chứng chỉ SSL
    sudo systemctl enable certbot.timer
    sudo systemctl start certbot.timer

    # Thêm vào cấu hình Nginx để chuyển hướng tất cả HTTP sang HTTPS
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo sed -i '/server {/a \    return 301 https://$host$request_uri;' /etc/nginx/nginx.conf
    sudo sed -i 's/listen 80;/listen 80;\n    return 301 https:\/\/$host$request_uri;/' $NGINX_CONF

    # Reload nginx
    sudo nginx -t && sudo systemctl reload nginx

    echo "✅ SSL đã được cài đặt và cấu hình cho domain $DOMAIN."
    
    # Cập nhật WordPress để sử dụng HTTPS
    sudo wp option update home "https://$DOMAIN" --path="/var/www/$DOMAIN"
    sudo wp option update siteurl "https://$DOMAIN" --path="/var/www/$DOMAIN"

    # Buộc WordPress sử dụng HTTPS cho admin
    WP_CONFIG="/var/www/$DOMAIN/wp-config.php"
    if ! grep -q "FORCE_SSL_ADMIN" "$WP_CONFIG"; then
        echo "define('FORCE_SSL_ADMIN', true);" | sudo tee -a "$WP_CONFIG"
        echo "✅ Đã thêm cấu hình FORCE_SSL_ADMIN vào wp-config.php."
    fi
}

function install_lemp() {
    echo "📦 Cài đặt LEMP stack..."
    sudo dnf update -y
    sudo dnf install -y dnf-plugins-core
    sudo dnf install -y epel-release
    sudo dnf module enable php:$PHP_VERSION -y
    sudo dnf install -y nginx mariadb-server php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-mysql \
        php$PHP_VERSION-curl php$PHP_VERSION-xml php$PHP_VERSION-mbstring php$PHP_VERSION-zip \
        php$PHP_VERSION-gd php$PHP_VERSION-intl php$PHP_VERSION-bcmath php$PHP_VERSION-soap \
        php$PHP_VERSION-imagick php$PHP_VERSION-exif php$PHP_VERSION-opcache php$PHP_VERSION-cli php$PHP_VERSION-readline \
        unzip wget curl

    echo "🔀 Tăng cấu hình PHP..."
    sudo sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 512M/' /etc/php/$PHP_VERSION/fpm/php.ini
    sudo sed -i 's/^post_max_size = .*/post_max_size = 512M/' /etc/php/$PHP_VERSION/fpm/php.ini
    sudo sed -i 's/^max_execution_time = .*/max_execution_time = 300/' /etc/php/$PHP_VERSION/fpm/php.ini
    sudo sed -i 's/^max_input_time = .*/max_input_time = 300/' /etc/php/$PHP_VERSION/fpm/php.ini
    sudo sed -i 's/^memory_limit = .*/memory_limit = 1024M/' /etc/php/$PHP_VERSION/fpm/php.ini

    if ! grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a \    client_max_body_size 512M;' /etc/nginx/nginx.conf
    fi

    sudo systemctl restart php$PHP_VERSION-fpm
    sudo systemctl enable nginx mariadb php$PHP_VERSION-fpm

    # Vô hiệu hóa SELinux và tạo swap ngay sau khi cài LEMP
    disable_selinux
    create_swap

    sudo touch "$LEMP_INSTALLED_FLAG"
    echo "✅ Hoàn tất cài LEMP stack"
}

function create_site() {
    echo "🌐 Tạo site WordPress mới"
    read -p "Nhập domain (VD: site1.local): " DOMAIN
    WEBROOT="/var/www/$DOMAIN"
    DB_NAME="${DOMAIN//./_}_db"
    DB_USER="${DOMAIN//./_}_user"
    DB_PASS=$(openssl rand -base64 12)

    read -p "👤 Nhập tên tài khoản admin (mặc định: admin): " ADMIN_USER
    read -p "📧 Nhập email admin (mặc định: admin@$DOMAIN): " ADMIN_EMAIL
    read -s -p "🔑 Nhập mật khẩu admin (Enter để tạo ngẫu nhiên): " ADMIN_PASS_INPUT
    echo

    ADMIN_USER=${ADMIN_USER:-admin}
    ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}
    ADMIN_PASS=${ADMIN_PASS_INPUT:-$(openssl rand -base64 10)}

    sudo mkdir -p "$WEBROOT"
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
    tar -xzf /tmp/latest.tar.gz -C /tmp
    sudo cp -r /tmp/wordpress/* "$WEBROOT"
    sudo chown -R www-data:www-data "$WEBROOT"
    sudo chmod -R 755 "$WEBROOT"

    sudo mariadb -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mariadb -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    sudo mariadb -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    sudo mariadb -e "FLUSH PRIVILEGES;"

    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo tee "$NGINX_CONF" > /dev/null <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx

    if ! command -v wp &> /dev/null; then
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        sudo mv wp-cli.phar /usr/local/bin/wp
    fi

    sudo -u www-data wp core config --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --path="$WEBROOT" --skip-check
    sudo -u www-data wp core install --url="http://$DOMAIN" --title="Website $DOMAIN" --admin_user="$ADMIN_USER" --admin_password="$ADMIN_PASS" --admin_email="$ADMIN_EMAIL" --path="$WEBROOT"
    sudo -u www-data wp plugin install woocommerce wordpress-seo contact-form-7 classic-editor --activate --path="$WEBROOT"

    sudo -u www-data mkdir -p "$WEBROOT/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$WEBROOT/wp-content/uploads/wc-logs"
    sudo chown -R www-data:www-data "$WEBROOT/wp-content/uploads/wc-logs"

    sudo -u www-data wp rewrite structure '/%postname%/' --path="$WEBROOT"
    sudo -u www-data wp rewrite flush --hard --path="$WEBROOT"
    sudo -u www-data wp post update 2 --post_title='Home' --post_name='home' --path="$WEBROOT"
    sudo -u www-data wp option update show_on_front 'page' --path="$WEBROOT"
    sudo -u www-data wp option update page_on_front 2 --path="$WEBROOT"

    echo "✅ Đã tạo site http://$DOMAIN"
    echo "📁 Webroot: $WEBROOT"
    echo "🛠️ DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
    echo "👤 WP Admin: $ADMIN_USER | Mật khẩu: $ADMIN_PASS"

    # Hỏi người dùng có muốn cài đặt SSL không
    read -p "🔒 Bạn có muốn cài đặt SSL cho site này không? (y/N): " SSL_CHOICE
    if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
        install_ssl "$DOMAIN"
    fi
}

# === MENU CHÍNH ===
while true; do
    echo ""
    echo "========= WORDPRESS MANAGER ========="
    echo "1. Cài đặt LEMP stack"
    echo "2. Tạo site WordPress mới"
    echo "3. Xoá site WordPress"
    echo "4. Restart dịch vụ"
    echo "5. Liệt kê site"
    echo "6. Clone site WordPress"
    echo "0. Thoát"
    echo "====================================="
    read -p "🔛 Nhập lựa chọn: " CHOICE

    case "$CHOICE" in
        1)
            if [ -f "$LEMP_INSTALLED_FLAG" ]; then
                echo "✅ LEMP đã được cài đặt."
                echo "1. Kiểm tra trạng thái LEMP"
                echo "2. Cài lại LEMP stack"
                echo "0. Quay lại menu chính"
                read -p "🔁 Chọn hành động: " SUBCHOICE
                case "$SUBCHOICE" in
                    1)
                        echo "✅ LEMP đã được cài đặt trước đó. Bao gồm:"
                        echo "   - Nginx"
                        echo "   - MariaDB"
                        echo "   - PHP $PHP_VERSION và các extension cần thiết"
                        ;;
                    2)
                        echo "♻️ Đang cài lại LEMP stack..."
                        install_lemp
                        ;;
                    0)
                        ;;  # quay lại menu chính
                    *)
                        echo "❌ Lựa chọn không hợp lệ!"
                        ;;
                esac
            else
                echo "📦 LEMP chưa được cài. Đang tiến hành cài đặt..."
                install_lemp
            fi
            ;;
        2) create_site ;;
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
