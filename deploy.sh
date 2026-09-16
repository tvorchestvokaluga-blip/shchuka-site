#!/usr/bin/env bash
# Развёртывание сайта художественной школы «Щука» на Ubuntu 22.04
# Запуск на сервере из-под root:
#   curl -fsSL https://raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/deploy.sh | bash
#
# Скрипт можно запускать повторно — он обновит сайт до свежей версии из репозитория.

set -euo pipefail

REPO="https://github.com/tvorchestvokaluga-blip/shchuka-site.git"
ROOT="/var/www/shchuka"
DOMAIN="xn--80aai0ag2ckyj.xn--p1ai"

echo "==> Обновляю списки пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "==> Ставлю nginx и git"
apt-get install -y -qq nginx git curl ca-certificates >/dev/null

echo "==> Забираю сайт из репозитория"
if [ -d "$ROOT/.git" ]; then
  git -C "$ROOT" fetch --depth 1 origin main
  git -C "$ROOT" reset --hard origin/main
else
  rm -rf "$ROOT"
  git clone --depth 1 "$REPO" "$ROOT"
fi
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;

echo "==> Настраиваю nginx"
cat > /etc/nginx/sites-available/shchuka <<'NGINXCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name xn--80aai0ag2ckyj.xn--p1ai www.xn--80aai0ag2ckyj.xn--p1ai _;

    root /var/www/shchuka;
    index index.html;
    charset utf-8;

    # страницы
    location / {
        try_files $uri $uri/ =404;
    }

    # статика кэшируется на месяц
    location ~* \.(jpg|jpeg|png|gif|webp|svg|ico|css|js|woff|woff2|ttf|pdf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # сжатие
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml application/javascript application/json image/svg+xml;

    # базовая защита заголовками
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # служебные файлы репозитория наружу не отдаём
    location ~ /\.(git|gitignore) { deny all; }
    location ~ /(deploy\.sh|README\.md)$ { deny all; }

    error_page 404 /index.html;
}
NGINXCONF

ln -sf /etc/nginx/sites-available/shchuka /etc/nginx/sites-enabled/shchuka
rm -f /etc/nginx/sites-enabled/default

echo "==> Проверяю конфиг"
nginx -t

systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

echo "==> Открываю порты в фаерволе"
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 'Nginx Full' >/dev/null 2>&1 || true
fi

IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "адрес сервера")

echo
echo "============================================"
echo "  Готово. Сайт развёрнут."
echo
echo "  Проверьте: http://$IP/"
echo
echo "  Домен $DOMAIN подключим отдельно,"
echo "  после того как A-записи будут переведены"
echo "  на этот сервер."
echo "============================================"
