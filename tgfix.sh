#!/usr/bin/env bash
# Диагностика и починка связи сервера с Telegram Bot API.
# На сервере DNS отдаёт для api.telegram.org только IPv6-адрес, а IPv6-маршрута нет —
# из-за этого заявки не уходят. Скрипт находит рабочий IPv4 и закрепляет его в /etc/hosts.
#
#   curl -fsSL -o /tmp/tgfix.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/tgfix.sh
#   bash /tmp/tgfix.sh

set -uo pipefail

HOST="api.telegram.org"
CANDIDATES="149.154.167.220 149.154.167.197 149.154.167.198 149.154.164.220"

echo "==> Что отдаёт DNS сейчас"
getent ahosts "$HOST" || echo "    (ничего)"

echo
echo "==> Ищу рабочий IPv4"
GOOD=""
for ip in $CANDIDATES; do
  code=$(curl -sS --max-time 8 --resolve "$HOST:443:$ip" \
           -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo 000)
  echo "    $ip -> $code"
  if [ "$code" != "000" ]; then GOOD="$ip"; break; fi
done

if [ -z "$GOOD" ]; then
  echo
  echo "!!! Ни один адрес Telegram недоступен с этого сервера."
  echo "!!! Похоже, провайдер блокирует Bot API. Заявки придётся слать другим способом."
  exit 1
fi

echo
echo "==> Закрепляю $GOOD в /etc/hosts"
sed -i "/[[:space:]]$HOST\$/d" /etc/hosts
echo "$GOOD $HOST" >> /etc/hosts
getent ahosts "$HOST" | head -3

echo
echo "==> Перезапускаю сервис и шлю тестовую заявку"
systemctl restart shchuka-bot
sleep 2
systemctl is-active shchuka-bot
curl -sS -X POST "http://127.0.0.1:8081/api/zayavka" \
  -H "Content-Type: application/json" \
  --data '{"name":"Проверка связи","phone":"+7 953 464-96-71","age":"6-7 лет","comment":"Тестовая заявка после починки сети."}'
echo
echo
journalctl -u shchuka-bot -n 15 --no-pager | tail -15

echo
echo "============================================"
echo "  Если выше {\"ok\"true} и сообщение пришло в чат — всё работает."
echo "============================================"
