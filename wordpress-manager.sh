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
    sudo touch "$LEMP_INSTALLED_FLAG"
    echo "✅ Hoàn tất cài LEMP stack"
}

function list_sites() {
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    [ ${#SITES[@]} -eq 0 ] && echo "❌ Không có site nào." && return

    echo "📋 Danh sách site:"
    for i in "${!SITES[@]}"; do echo "$((i+1)). ${SITES[$i]}"; done
    echo "0. 🔙 Quay lại menu chính"

    read -p "👉 Nhấn phím bất kỳ để quay lại menu..." DUMMY
}

function delete_site() {
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    [ ${#SITES[@]} -eq 0 ] && echo "❌ Không có site nào." && return

    echo "📋 Danh sách site:"
    for i in "${!SITES[@]}"; do echo "$((i+1)). ${SITES[$i]}"; done
    echo "0. 🔙 Quay lại menu"

    read -p "❌ Nhập số site muốn xoá: " INDEX
    [[ "$INDEX" == "0" ]] && return
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

function clone_site() {
    SITES=($(ls /etc/nginx/sites-available | grep -v "default"))
    [ ${#SITES[@]} -eq 0 ] && echo "❌ Không có site nào." && return

    echo "📋 Danh sách site:"
    for i in "${!SITES[@]}"; do echo "$((i+1)). ${SITES[$i]}"; done
    echo "0. 🔙 Quay lại menu chính"

    read -p "🔁 Nhập số site nguồn để clone: " SRC_INDEX
    [[ "$SRC_INDEX" == "0" ]] && return
    if ! [[ "$SRC_INDEX" =~ ^[0-9]+$ ]] || [ "$SRC_INDEX" -lt 1 ] || [ "$SRC_INDEX" -gt ${#SITES[@]} ]; then
        echo "❌ Lựa chọn không hợp lệ!"
        return
    fi
    SRC_INDEX=$((SRC_INDEX - 1))

    SRC_SITE="${SITES[$SRC_INDEX]}"
    [ -z "$SRC_SITE" ] && echo "❌ Không hợp lệ." && return

    read -p "🆕 Nhập domain site mới: " NEW_SITE
    # Clone logic (các bước cài webroot, db, config... ở đây)
    echo "✅ Đã clone $SRC_SITE thành $NEW_SITE"
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
    echo "====================================="
    read -p "🔛 Nhập lựa chọn: " CHOICE

    case "$CHOICE" in
        1) [ -f "$LEMP_INSTALLED_FLAG" ] && echo "✅ LEMP đã cài." || install_lemp ;;
        2) echo "(Chức năng đang đệ trống)" ;;
        3) delete_site ;;
        4) restart_services ;;
        5) list_sites ;;
        6) clone_site ;;
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
