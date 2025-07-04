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
            0) continue ;;
            *) echo "❌ Lựa chọn không hợp lệ!" ;;
        esac
    else
        echo "📦 LEMP chưa được cài. Đang tiến hành cài đặt..."
        install_lemp
    fi ;;
                    0) continue ;;
                    *) echo "❌ Lựa chọn không hợp lệ!" ;;
                esac
            else
                install_lemp
            fi
            ;;
        2) add_site ;;
        3) delete_site ;;
        4) restart_services ;;
        5) list_sites ;;
        6) clone_site ;;
        0) echo "👋 Thoát."; exit ;;
        *) echo "❌ Lựa chọn không hợp lệ!" ;;
    esac
done
