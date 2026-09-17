#!/usr/bin/env bash
# Выпуск бесплатного сертификата Let's Encrypt и включение HTTPS
# Запуск на сервере из-под root:
#   curl -fsSL -o /tmp/ssl.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/ssl.sh
#   bash /tmp/ssl.sh
#
# Требование: A-записи домена уже должны указывать на этот сервер.

set -euo pipefail

DOMAIN="xn--80aai0ag2ckyj.xn--p1ai"
EMAIL="hsh_kaluga@mail.ru"

echo "==> Ставлю certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq certbot python3-certbot-nginx >/dev/null

echo "==> Проверяю, что домен смотрит на этот сервер"
SERVER_IP=$(curl -fsS --max-time 10 https://api.ipify.org)
DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1)
echo "    сервер: $SERVER_IP"
echo "    домен:  $DOMAIN_IP"
if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  echo "!!! Домен указывает не на этот сервер. Сертификат выпустить нельзя."
  echo "!!! Исправьте A-запись и запустите скрипт заново."
  exit 1
fi

echo "==> Выпускаю сертификат"
certbot --nginx \
  -d "$DOMAIN" \
  -d "www.$DOMAIN" \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  --redirect \
  --keep-until-expiring

echo "==> Проверяю автопродление"
systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true
certbot renew --dry-run

systemctl reload nginx

echo
echo "============================================"
echo "  Готово. HTTPS включён."
echo
echo "  Сайт: https://xn--80aai0ag2ckyj.xn--p1ai/"
echo "  (в адресной строке — хшщкалуга.рф)"
echo
echo "  Сертификат продлевается автоматически."
echo "============================================"
