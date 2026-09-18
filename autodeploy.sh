#!/usr/bin/env bash
# Автообновление сайта: раз в 2 минуты сервер сам подтягивает свежую версию из GitHub.
# Ставится один раз:
#   curl -fsSL -o /tmp/autodeploy.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/autodeploy.sh
#   bash /tmp/autodeploy.sh

set -euo pipefail

ROOT="/var/www/shchuka"

git config --global --add safe.directory "$ROOT" 2>/dev/null || true

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
systemctl enable --now shchuka-update.timer
/usr/local/bin/shchuka-update

echo
echo "============================================"
echo "  Готово. Сайт теперь обновляется сам."
echo "  Любой новый коммит в GitHub приезжает"
echo "  на сервер в течение двух минут."
echo
echo "  Обновить прямо сейчас: shchuka-update"
echo "============================================"
