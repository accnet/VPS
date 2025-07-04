#!/bin/bash

LEMP_INSTALLED_FLAG="/var/local/lemp_installed.flag"
PHP_VERSION="8.2"

function install_lemp() {
    echo "📦 Gỡ apache2 nếu có..."
    sudo systemctl stop apache2 2>/dev/null
    sudo systemctl disable apache2 2>/dev/null
    sudo apt remove --purge apache2 apache2-utils apache2-bin -y
    sudo apt autoremove -y
    sudo apt-mark hold apache2 apache2-bin

    echo "📦 Cài đặt LEMP stack..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update

    sudo apt install -y nginx mariadb-server php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-mysql \
        php$PHP_VERSION-curl php$PHP_VERSION-xml php$PHP_VERSION-mbstring php$PHP_VERSION-zip unzip wget curl

    echo "🛠️ Tăng cấu hình PHP..."
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
    sudo touch "$LEMP_INSTALLED_FLAG"
    echo "✅ Hoàn tất cài LEMP stack"
}

function add_site() {
    read -p "🌐 Nhập domain (VD: site1.local): " DOMAIN
    DB_NAME="${DOMAIN//./_}_db"
    DB_USER="${DOMAIN//./_}_user"
    DB_PASS=$(openssl rand -base64 12)
    WEBROOT="/var/www/$DOMAIN"

    read -p "👤 Nhập tên tài khoản admin (mặc định: admin): " ADMIN_USER
    read -p "✉️  Nhập email admin (mặc định: admin@$DOMAIN): " ADMIN_EMAIL
    read -s -p "🔑 Nhập mật khẩu admin (Enter để tạo ngẫu nhiên): " ADMIN_PASS_INPUT
    echo ""

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

    # Fix: WooCommerce logs permission
    sudo -u www-data mkdir -p "$WEBROOT/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$WEBROOT/wp-content/uploads/wc-logs"
    sudo chown -R www-data:www-data "$WEBROOT/wp-content/uploads/wc-logs"

    echo ""
    echo "✅ Đã tạo site http://$DOMAIN"
    echo "📁 Webroot: $WEBROOT"
    echo "🛠️ DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
    echo "👤 WP Admin: $ADMIN_USER | Mật khẩu: $ADMIN_PASS"
}

function delete_site() {
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    [ ${#SITES[@]} -eq 0 ] && echo "❌ Không có site nào." && return
    for i in "${!SITES[@]}"; do echo "$((i+1)). ${SITES[$i]}"; done
    read -p "❌ Nhập số site muốn xoá: " INDEX
    INDEX=$((INDEX-1))
    SITE="${SITES[$INDEX]}"
    [ -z "$SITE" ] && echo "❌ Không hợp lệ." && return
    read -p "Bạn chắc chắn muốn xoá $SITE? (y/N): " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && return
    sudo rm -rf "/var/www/$SITE"
    sudo rm -f "/etc/nginx/sites-available/$SITE" "/etc/nginx/sites-enabled/$SITE"
    DB_NAME="${SITE//./_}_db"
    DB_USER="${SITE//./_}_user"
    sudo mariadb -e "DROP DATABASE IF EXISTS $DB_NAME;"
    sudo mariadb -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
    sudo nginx -t && sudo systemctl reload nginx
    echo "✅ Đã xoá site $SITE"
}

function list_sites() {
    ls /etc/nginx/sites-available | grep -v "default"
}

function restart_services() {
    sudo systemctl restart nginx php$PHP_VERSION-fpm mariadb
    echo "✅ Đã restart Nginx, PHP-FPM, MariaDB"
}

function clone_site() {
    list_sites
    read -p "🔁 Nhập số site nguồn để clone: " SRC_INDEX
    SRC_INDEX=$((SRC_INDEX - 1))
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    SRC_SITE="${SITES[$SRC_INDEX]}"
    [ -z "$SRC_SITE" ] && echo "❌ Không hợp lệ." && return

    read -p "🆕 Nhập domain site mới: " NEW_SITE
    WEBROOT_NEW="/var/www/$NEW_SITE"
    WEBROOT_SRC="/var/www/$SRC_SITE"

    DB_SRC="${SRC_SITE//./_}_db"
    DB_NEW="${NEW_SITE//./_}_db"
    USER_SRC="${SRC_SITE//./_}_user"
    USER_NEW="${NEW_SITE//./_}_user"
    PASS_NEW=$(openssl rand -base64 12)

    sudo cp -r "$WEBROOT_SRC" "$WEBROOT_NEW"
    sudo chown -R www-data:www-data "$WEBROOT_NEW"

    sudo mariadb -e "CREATE DATABASE $DB_NEW CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mariadb -e "CREATE USER '$USER_NEW'@'localhost' IDENTIFIED BY '$PASS_NEW';"
    sudo mariadb -e "GRANT ALL PRIVILEGES ON $DB_NEW.* TO '$USER_NEW'@'localhost';"
    sudo mariadb -e "FLUSH PRIVILEGES;"
    sudo mariadb "$DB_NEW" < <(sudo mariadb-dump "$DB_SRC")

    sudo sed -i "s/'DB_NAME', *'.*'/'DB_NAME', '$DB_NEW'/" "$WEBROOT_NEW/wp-config.php"
    sudo sed -i "s/'DB_USER', *'.*'/'DB_USER', '$USER_NEW'/" "$WEBROOT_NEW/wp-config.php"
    sudo sed -i "s/'DB_PASSWORD', *'.*'/'DB_PASSWORD', '$PASS_NEW'/" "$WEBROOT_NEW/wp-config.php"

    sudo cp "/etc/nginx/sites-available/$SRC_SITE" "/etc/nginx/sites-available/$NEW_SITE"
    sudo sed -i "s/$SRC_SITE/$NEW_SITE/g" "/etc/nginx/sites-available/$NEW_SITE"
    sudo ln -sf "/etc/nginx/sites-available/$NEW_SITE" "/etc/nginx/sites-enabled/"
    sudo nginx -t && sudo systemctl reload nginx

    # WooCommerce log fix
    sudo -u www-data mkdir -p "$WEBROOT_NEW/wp-content/uploads/wc-logs"
    sudo chmod -R 775 "$WEBROOT_NEW/wp-content/uploads/wc-logs"
    sudo chown -R www-data:www-data "$WEBROOT_NEW/wp-content/uploads/wc-logs"

    sudo -u www-data wp option update siteurl "http://$NEW_SITE" --path="$WEBROOT_NEW"
    sudo -u www-data wp option update home "http://$NEW_SITE" --path="$WEBROOT_NEW"

    echo "✅ Đã clone $SRC_SITE thành $NEW_SITE"
    echo "🌐 http://$NEW_SITE"
    echo "🛠️ DB: $DB_NEW | User: $USER_NEW | Pass: $PASS_NEW"
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
    read -p "👉 Nhập lựa chọn: " CHOICE

    case "$CHOICE" in
        1) [ -f "$LEMP_INSTALLED_FLAG" ] && echo "✅ LEMP đã cài." || install_lemp ;;
        2) add_site ;;
        3) delete_site ;;
        4) restart_services ;;
        5) list_sites ;;
        6) clone_site ;;
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
