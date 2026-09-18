#!/usr/bin/env bash
# Один раз запускается на сервере и делает три вещи:
#   1) включает автообновление сайта из GitHub (каждые 2 минуты);
#   2) запрещает браузерам кэшировать html — иначе люди видят старую версию страницы;
#   3) кладёт диагностику в /diag.txt, чтобы её можно было прочитать снаружи.
#
#   curl -fsSL -o /tmp/autodeploy.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/autodeploy.sh
#   bash /tmp/autodeploy.sh

set -euo pipefail

ROOT="/var/www/shchuka"
git config --global --add safe.directory "$ROOT" 2>/dev/null || true

echo "==> Ставлю автообновление"
cat > /usr/local/bin/shchuka-update <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="/var/www/shchuka"
git -C "$ROOT" fetch --depth 1 origin main --quiet
LOCAL=$(git -C "$ROOT" rev-parse HEAD)
REMOTE=$(git -C "$ROOT" rev-parse origin/main)
if [ "$LOCAL" = "$REMOTE" ]; then
  echo "уже последняя версия"
  exit 0
fi
git -C "$ROOT" reset --hard origin/main --quiet
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;
if nginx -t >/dev/null 2>&1; then systemctl reload nginx; fi
echo "обновлено до $REMOTE"
SH
chmod 755 /usr/local/bin/shchuka-update

cat > /etc/systemd/system/shchuka-update.service <<'UNIT'
[Unit]
Description=Obnovlenie sayta iz GitHub
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/shchuka-update
UNIT

cat > /etc/systemd/system/shchuka-update.timer <<'UNIT'
[Unit]
Description=Proverka obnovleniy sayta kazhdye 2 minuty

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now shchuka-update.timer >/dev/null 2>&1

echo "==> Запрещаю кэшировать html и подключаю диагностику"
install -d -m 755 /etc/nginx/snippets
cat > /etc/nginx/snippets/shchuka-api.conf <<'SNIP'
location = /api/zayavka {
    proxy_pass http://127.0.0.1:8081/api/zayavka;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 30s;
    access_log /var/log/nginx/zayavki.log;
}

# страницы всегда берём свежие, иначе у людей остаётся старая версия сайта
location = / {
    add_header Cache-Control "no-cache, must-revalidate" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    try_files /index.html =404;
}
location ~* \.html$ {
    add_header Cache-Control "no-cache, must-revalidate" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}

# служебные скрипты наружу не отдаём
location ~ ^/(deploy|ssl|telegram|tgfix|autodeploy)\.sh$ { deny all; }
SNIP

python3 - <<'PY'
path = "/etc/nginx/sites-available/shchuka"
inc = "    include /etc/nginx/snippets/shchuka-api.conf;\n"
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
if any("shchuka-api.conf" in line for line in lines):
    print("    подключено уже было")
else:
    out = []
    for line in lines:
        out.append(line)
        if line.strip() == "root /var/www/shchuka;":
            out.append(inc)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print("    добавлено")
PY

nginx -t
systemctl reload nginx

echo "==> Обновляю сайт"
/usr/local/bin/shchuka-update || true

echo "==> Собираю диагностику в /diag.txt"
{
  echo "Диагностика от $(date '+%d.%m.%Y %H:%M:%S %Z')"
  echo
  echo "--- версия сайта на сервере ---"
  git -C "$ROOT" log -1 --format='%h %ad %s' --date=format:'%d.%m %H:%M' 2>&1
  echo
  echo "--- сервис приёма заявок ---"
  systemctl is-active shchuka-bot 2>&1
  echo
  echo "--- закреплён ли адрес Telegram ---"
  grep -c api.telegram.org /etc/hosts 2>&1
  echo
  echo "--- последние 40 обращений к форме (кто, когда, какой ответ) ---"
  tail -n 40 /var/log/nginx/zayavki.log 2>&1 || echo "лог пока пуст"
  echo
  echo "--- ошибки сервиса за сутки ---"
  journalctl -u shchuka-bot --since '24 hours ago' --no-pager 2>&1 | grep -i 'fail\|error' | tail -n 20 || echo "ошибок нет"
} > "$ROOT/diag.txt" 2>&1
chmod 644 "$ROOT/diag.txt"
chown www-data:www-data "$ROOT/diag.txt"

echo
echo "============================================"
echo "  Готово."
echo
echo "  1. Сайт теперь обновляется сам каждые 2 минуты."
echo "  2. Браузеры больше не показывают старую версию."
echo "  3. Диагностика лежит по адресу /diag.txt"
echo "============================================"
