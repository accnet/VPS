#!/bin/bash

LEMP_INSTALLED_FLAG="/var/local/lemp_installed.flag"
PHP_VERSION="8.2"

function disable_selinux() {
    echo "🔒 Vô hiệu hóa SELinux..."
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    echo "✅ SELinux đã được vô hiệu hóa."
}

function create_swap() {
    echo "🔄 Kiểm tra RAM và tạo swap..."
    RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
    SWAP_SIZE=$((RAM_SIZE * 2))  # Tạo swap gấp đôi dung lượng RAM

    # Kiểm tra xem swap có tồn tại không, nếu không thì tạo mới
    if [ ! -f /swapfile ]; then
        sudo fallocate -l ${SWAP_SIZE}M /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
        echo "✅ Đã tạo swap file với dung lượng ${SWAP_SIZE}MB."
    else
        echo "❌ Swap file đã tồn tại."
    fi
}

function install_lemp() {
    echo "📦 Gỡ apache2 nếu có..."
    sudo systemctl stop apache2 2>/dev/null
    sudo systemctl disable apache2 2>/dev/null
    sudo apt remove --purge apache2 apache2-utils apache2-bin -y
    sudo apt autoremove -y
    sudo apt-mark hold apache2 apache2-bin

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
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
