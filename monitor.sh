#!/usr/bin/env bash
# Ставит на сервер круглосуточную проверку сайта (monitor.py).
#
# Запуск в консоли Selectel из-под root — команда без символов, которые консоль путает:
#   bash /var/www/shchuka/monitor.sh
#
# Что появится:
#   - каждые 30 минут быстрая проверка; в Telegram пишет, только если что-то сломалось;
#   - каждый день в 10:00 по Москве полная проверка с тестовой заявкой через сайт;
#   - результат последней проверки: https://хшщкалуга.рф/monitor.txt
# Дальнейшие правки monitor.py подтягиваются с GitHub сами (через shchuka-update).

set -euo pipefail
ROOT="/var/www/shchuka"

if [ ! -f "$ROOT/monitor.py" ]; then
  echo "Файл monitor.py ещё не пришёл с GitHub. Подождите 2 минуты и запустите снова."
  exit 1
fi

echo "==> Копирую проверку"
install -d -m 755 /opt/shchuka-monitor /var/lib/shchuka-monitor
install -m 755 "$ROOT/monitor.py" /opt/shchuka-monitor/monitor.py

echo "==> Ставлю расписание"
cat > /etc/systemd/system/shchuka-monitor.service <<'UNIT'
[Unit]
Description=Bystraya proverka sayta
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/shchuka-monitor/monitor.py quick
TimeoutStartSec=15min
UNIT

cat > /etc/systemd/system/shchuka-monitor.timer <<'UNIT'
[Unit]
Description=Proverka sayta kazhdye 30 minut

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/shchuka-monitor-daily.service <<'UNIT'
[Unit]
Description=Polnaya proverka sayta s testovoy zayavkoy
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/shchuka-monitor/monitor.py daily
TimeoutStartSec=20min
UNIT

cat > /etc/systemd/system/shchuka-monitor-daily.timer <<'UNIT'
[Unit]
Description=Polnaya proverka sayta raz v den

[Timer]
OnCalendar=*-*-* 07:00:00 UTC
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now shchuka-monitor.timer shchuka-monitor-daily.timer >/dev/null 2>&1

echo "==> Включаю автообновление проверки из GitHub"
python3 - <<'PY'
path = "/usr/local/bin/shchuka-update"
block = '''# проверка сайта тоже живёт в репозитории — обновляем и её
if [ -f "$ROOT/monitor.py" ] && ! cmp -s "$ROOT/monitor.py" /opt/shchuka-monitor/monitor.py; then
  install -d -m 755 /opt/shchuka-monitor
  install -m 755 "$ROOT/monitor.py" /opt/shchuka-monitor/monitor.py
  echo "проверка сайта обновлена"
fi
'''
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except FileNotFoundError:
    print("    shchuka-update не найден — пропускаю")
    raise SystemExit
if "shchuka-monitor" in text:
    print("    уже включено")
else:
    marker = "if nginx -t"
    if marker in text:
        text = text.replace(marker, block + marker, 1)
    else:
        text += "\n" + block
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("    включено")
PY

echo "==> Закрываю служебные файлы от посторонних"
python3 - <<'PY'
import shutil, subprocess
path = "/etc/nginx/snippets/shchuka-api.conf"
rule = "\n# файлы проверки сайта наружу не отдаём\nlocation ~ ^/monitor\\.(sh|py)$ { deny all; }\n"
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except FileNotFoundError:
    print("    конфиг nginx не найден — пропускаю")
    raise SystemExit
if "monitor\\." in text:
    print("    уже закрыто")
    raise SystemExit
shutil.copy(path, path + ".bak")
with open(path, "a", encoding="utf-8") as f:
    f.write(rule)
if subprocess.run(["nginx", "-t"], capture_output=True).returncode == 0:
    subprocess.run(["systemctl", "reload", "nginx"])
    print("    закрыто")
else:
    shutil.copy(path + ".bak", path)
    print("    nginx не принял правило — вернул как было")
PY

echo "==> Первая полная проверка (в группу придёт тестовая заявка)"
/usr/bin/python3 /opt/shchuka-monitor/monitor.py daily || true

echo
echo "============================================"
echo "  Готово. Сайт проверяется сам, даже когда"
echo "  компьютер выключен."
echo
echo "  Каждые 30 минут — быстрая проверка."
echo "  Каждый день в 10 утра — тестовая заявка."
echo "  Итог последней проверки — /monitor.txt"
echo "============================================"
