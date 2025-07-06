#!/bin/bash

# ❗ Chặn cài đặt trên Ubuntu 24
if grep -q 'Ubuntu 24' /etc/os-release; then
    echo "⚠️ Cảnh báo: Script chưa được kiểm thử trên Ubuntu 24. Một số chức năng có thể không hoạt động chính xác."
fi

LEMP_INSTALLED_FLAG="/var/local/lemp_installed.flag"
PHP_VERSION="8.2"
PHP_FPM_POOL="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"

function install_lemp() {
    echo "📦 Cài đặt LEMP stack..."
    sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -yq --allow-downgrades --allow-remove-essential --allow-change-held-packages
    sudo apt install -yq software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update

    sudo apt install -yq nginx mariadb-server php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-mysql \
        php$PHP_VERSION-curl php$PHP_VERSION-xml php$PHP_VERSION-mbstring php$PHP_VERSION-zip \
        php$PHP_VERSION-gd php$PHP_VERSION-intl php$PHP_VERSION-bcmath php$PHP_VERSION-soap \
        php$PHP_VERSION-imagick php$PHP_VERSION-exif php$PHP_VERSION-opcache php$PHP_VERSION-cli php$PHP_VERSION-readline \
        unzip wget curl

    echo "🔀 Tăng cấu hình PHP..."
    if [ -f /etc/php/$PHP_VERSION/fpm/php.ini ]; then
        sudo sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 512M/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^max_input_vars = .*/max_input_vars = 5000/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^realpath_cache_size = .*/realpath_cache_size = 4096k/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^realpath_cache_ttl = .*/realpath_cache_ttl = 600/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^post_max_size = .*/post_max_size = 512M/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^max_execution_time = .*/max_execution_time = 300/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^max_input_time = .*/max_input_time = 300/' /etc/php/$PHP_VERSION/fpm/php.ini
        sudo sed -i 's/^memory_limit = .*/memory_limit = 1024M/' /etc/php/$PHP_VERSION/fpm/php.ini
    fi

    if [ -f /etc/nginx/nginx.conf ] && ! grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a \    client_max_body_size 512M;' /etc/nginx/nginx.conf
    fi

    if [ -f /etc/php/$PHP_VERSION/fpm/php.ini ]; then
        sudo systemctl restart php$PHP_VERSION-fpm
    fi

    [ -f "$PHP_FPM_POOL" ] && sudo sed -i 's/^;*pm.max_children = .*/pm.max_children = 50/' "$PHP_FPM_POOL"
    [ -f "$PHP_FPM_POOL" ] && sudo sed -i 's/^;*pm.start_servers = .*/pm.start_servers = 14/' "$PHP_FPM_POOL"
    [ -f "$PHP_FPM_POOL" ] && sudo sed -i 's/^;*pm.min_spare_servers = .*/pm.min_spare_servers = 8/' "$PHP_FPM_POOL"
    [ -f "$PHP_FPM_POOL" ] && sudo sed -i 's/^;*pm.max_spare_servers = .*/pm.max_spare_servers = 20/' "$PHP_FPM_POOL"
    [ -f "$PHP_FPM_POOL" ] && sudo sed -i 's/^;*pm.max_requests = .*/pm.max_requests = 2000/' "$PHP_FPM_POOL"

    [ -f /etc/nginx/nginx.conf ] && sudo sed -i 's/^worker_connections .*/worker_connections 10240;/' /etc/nginx/nginx.conf
    if [ -f /etc/nginx/nginx.conf ] && ! grep -q 'sendfile on;' /etc/nginx/nginx.conf; then
    sudo sed -i '/http {/a \
    sendfile on;\
    tcp_nopush on;\
    tcp_nodelay on;\
    server_tokens off;\
    keepalive_timeout 60;\
    types_hash_max_size 4096;\
    client_body_buffer_size 256K;\
    client_header_buffer_size 2k;\
    large_client_header_buffers 4 16k;' /etc/nginx/nginx.conf
fi

    if [ -f /etc/nginx/nginx.conf ] && ! grep -q 'gzip on;' /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a \
    gzip on;
    gzip_disable \"msie6\";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;' /etc/nginx/nginx.conf
    fi

    sudo systemctl enable nginx mariadb php$PHP_VERSION-fpm
    sudo touch "$LEMP_INSTALLED_FLAG"
    echo "✅ Hoàn tất cài LEMP stack"
}
}

function list_sites() {
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    [ ${#SITES[@]} -eq 0 ] && echo "❌ Không có site nào." && return

    echo "📋 Danh sách site:"
    for i in "${!SITES[@]}"; do
        echo "$((i+1)). ${SITES[$i]}"
    done
    echo "0. 🔙 Quay lại menu chính"
    read -p "👉 Nhấn Enter để quay lại menu... " DUMMY
}

function restart_services() {
    sudo systemctl restart nginx php$PHP_VERSION-fpm mariadb
    echo "✅ Đã restart Nginx, PHP-FPM, MariaDB"
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
    echo "7. Cài SSL Let's Encrypt cho site"
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
        2)
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
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
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

            # Tối ưu PHP-FPM cho site vừa thêm
            sudo sed -i 's/^;*pm.max_children = .*/pm.max_children = 30/' "$PHP_FPM_POOL"
            sudo sed -i 's/^;*pm.start_servers = .*/pm.start_servers = 10/' "$PHP_FPM_POOL"
            sudo sed -i 's/^;*pm.min_spare_servers = .*/pm.min_spare_servers = 6/' "$PHP_FPM_POOL"
            sudo sed -i 's/^;*pm.max_spare_servers = .*/pm.max_spare_servers = 15/' "$PHP_FPM_POOL"
            sudo sed -i 's/^;*pm.max_requests = .*/pm.max_requests = 1000/' "$PHP_FPM_POOL"
            sudo systemctl restart php$PHP_VERSION-fpm

            # Tối ưu nginx per-site (thêm gzip và caching nếu cần)

            echo "✅ Đã tạo site http://$DOMAIN"
            echo "📁 Webroot: $WEBROOT"
            echo "🛠️ DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
            echo "👤 WP Admin: $ADMIN_USER | Mật khẩu: $ADMIN_PASS"

            read -p "🔐 Bạn có muốn cài SSL Let's Encrypt cho site này không? (y/N): " INSTALL_SSL
            if [[ "$INSTALL_SSL" == "y" || "$INSTALL_SSL" == "Y" ]]; then
                sudo apt install -y certbot python3-certbot-nginx
                sudo certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --agree-tos --no-eff-email --redirect --email "$ADMIN_EMAIL"

                CONF_FILE="/etc/nginx/sites-available/$DOMAIN"
                if ! grep -q 'return 301 https' "$CONF_FILE"; then
                    sudo sed -i "/server_name $DOMAIN;/a \
    return 301 https://\$host\$request_uri;" "$CONF_FILE"
                fi

                sudo nginx -t && sudo systemctl reload nginx

                sudo -u www-data wp option update home "https://$DOMAIN" --path="$WEBROOT"
                sudo -u www-data wp option update siteurl "https://$DOMAIN" --path="$WEBROOT"

                echo "✅ Đã cài SSL Let's Encrypt cho site: https://$DOMAIN"
            fi
            ;;
        3)
            SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
            if [ ${#SITES[@]} -eq 0 ]; then
                echo "❌ Không có site nào để xoá."
                break
            fi

            echo "🗑 Danh sách site:"
            for i in "${!SITES[@]}"; do
                echo "$((i+1)). ${SITES[$i]}"
            done
            echo "0. 🔙 Quay lại menu chính"
            read -p "❌ Nhập số thứ tự site muốn xoá: " DEL_INDEX

            if [[ "$DEL_INDEX" == "0" ]]; then
                continue
            fi

            DEL_INDEX=$((DEL_INDEX - 1))
            SITE="${SITES[$DEL_INDEX]}"
            if [ -z "$SITE" ]; then
                echo "❌ Lựa chọn không hợp lệ."
                continue
            fi

            read -p "Bạn có chắc chắn muốn xoá site '$SITE'? (y/N): " CONFIRM
            if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
                echo "🚫 Đã huỷ xoá."
                continue
            fi

            sudo rm -rf "/var/www/$SITE"
            sudo rm -f "/etc/nginx/sites-available/$SITE" "/etc/nginx/sites-enabled/$SITE"
            DB_NAME="${SITE//./_}_db"
            DB_USER="${SITE//./_}_user"
            sudo mariadb -e "DROP DATABASE IF EXISTS $DB_NAME;"
            sudo mariadb -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
            sudo nginx -t && sudo systemctl reload nginx

            echo "✅ Đã xoá site '$SITE' thành công."
            ;;
        4) restart_services ;;
        5) list_sites ;;
        6)
            SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
            if [ ${#SITES[@]} -eq 0 ]; then
                echo "❌ Không có site nào để clone."
                break
            fi

            echo "📋 Danh sách site hiện có:"
            for i in "${!SITES[@]}"; do
                echo "$((i+1)). ${SITES[$i]}"
            done
            echo "0. 🔙 Quay lại menu chính"
            read -p "🔁 Nhập số thứ tự site nguồn để clone: " SRC_INDEX
            if [[ "$SRC_INDEX" == "0" ]]; then
                continue
            fi

            SRC_INDEX=$((SRC_INDEX - 1))
            SRC_SITE="${SITES[$SRC_INDEX]}"
            if [ -z "$SRC_SITE" ]; then
                echo "❌ Lựa chọn không hợp lệ."
                continue
            fi

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

            sudo -u www-data wp option update siteurl "http://$NEW_SITE" --path="$WEBROOT_NEW"
            sudo -u www-data wp option update home "http://$NEW_SITE" --path="$WEBROOT_NEW"
            sudo -u www-data wp rewrite structure '/%postname%/' --path="$WEBROOT_NEW"
            sudo -u www-data wp rewrite flush --hard --path="$WEBROOT_NEW"
            sudo -u www-data wp post update 2 --post_title='Home' --post_name='home' --path="$WEBROOT_NEW"
            sudo -u www-data wp option update show_on_front 'page' --path="$WEBROOT_NEW"
            sudo -u www-data wp option update page_on_front 2 --path="$WEBROOT_NEW"

            sudo -u www-data mkdir -p "$WEBROOT_NEW/wp-content/uploads/wc-logs"
            sudo chmod -R 775 "$WEBROOT_NEW/wp-content/uploads/wc-logs"
            sudo chown -R www-data:www-data "$WEBROOT_NEW/wp-content/uploads/wc-logs"

            echo "✅ Đã clone $SRC_SITE thành $NEW_SITE"
            echo "🌐 http://$NEW_SITE"
            echo "🛠️ DB: $DB_NEW | User: $USER_NEW | Pass: $PASS_NEW"
            ;;
        7)
            SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
            if [ ${#SITES[@]} -eq 0 ]; then
                echo "❌ Không có site nào để cài SSL."
                break
            fi

            echo "🔒 Danh sách site để cài SSL Let's Encrypt:"
            for i in "${!SITES[@]}"; do
                echo "$((i+1)). ${SITES[$i]}"
            done
            echo "0. 🔙 Quay lại menu chính"
            read -p "🔐 Nhập số thứ tự site muốn thêm SSL: " SSL_INDEX

            if [[ "$SSL_INDEX" == "0" ]]; then
                continue
            fi

            SSL_INDEX=$((SSL_INDEX - 1))
            SITE="${SITES[$SSL_INDEX]}"
            if [ -z "$SITE" ]; then
                echo "❌ Lựa chọn không hợp lệ."
                continue
            fi

            sudo apt install -y certbot python3-certbot-nginx
            sudo certbot --nginx -d "$SITE" -d "www.$SITE" --agree-tos --no-eff-email --redirect --email "admin@$SITE"

            # Cập nhật file cấu hình Nginx nếu chưa có redirect HTTPS
            CONF_FILE="/etc/nginx/sites-available/$SITE"
            if ! grep -q 'return 301 https' "$CONF_FILE"; then
                sudo sed -i "/server_name $SITE;/a \n    return 301 https://\$host\$request_uri;" "$CONF_FILE"
            fi

            sudo nginx -t && sudo systemctl reload nginx

            # Ép WordPress hoạt động với HTTPS
            WEBROOT="/var/www/$SITE"
            sudo -u www-data wp option update home "https://$SITE" --path="$WEBROOT"
            sudo -u www-data wp option update siteurl "https://$SITE" --path="$WEBROOT"

            echo "✅ Đã cài SSL Let's Encrypt cho site: https://$SITE"
            ;;
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
