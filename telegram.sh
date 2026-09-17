#!/usr/bin/env bash
# Приём заявок с сайта в Telegram.
#
# Запуск на сервере из-под root (токен передаётся двумя частями — до и после двоеточия,
# потому что веб-консоль Selectel неправильно набирает символ «:»):
#   curl -fsSL -o /tmp/telegram.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/telegram.sh
#   bash /tmp/telegram.sh ЧАСТЬ1 ЧАСТЬ2 CHAT_ID
#
# Токен в репозитории НЕ хранится — он попадает только в /etc/shchuka-bot.env (права 600).

set -euo pipefail

P1="${1:?нужна первая часть токена}"
P2="${2:?нужна вторая часть токена}"
CHAT="${3:?нужен chat_id}"

TOKEN="${P1}$(printf '\072')${P2}"

echo "==> Пишу настройки"
install -d -m 755 /opt/shchuka-bot
umask 077
cat > /etc/shchuka-bot.env <<EOF
TG_TOKEN=${TOKEN}
TG_CHAT=${CHAT}
EOF
chmod 600 /etc/shchuka-bot.env
umask 022

echo "==> Ставлю сервис приёма заявок"
cat > /opt/shchuka-bot/app.py <<'PY'
# -*- coding: utf-8 -*-
"""Маленький сервис: принимает заявку с сайта и отправляет её в Telegram."""
import html
import json
import os
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ["TG_TOKEN"]
CHAT = os.environ["TG_CHAT"]
API = "https://api.telegram.org/bot%s/sendMessage" % TOKEN


def send(text):
    body = urllib.parse.urlencode(
        {"chat_id": CHAT, "text": text, "parse_mode": "HTML"}
    ).encode("utf-8")
    req = urllib.request.Request(API, data=body)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.status


class Handler(BaseHTTPRequestHandler):
    server_version = "shchuka"
    sys_version = ""

    def reply(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        if self.path.split("?")[0] != "/api/zayavka":
            return self.reply(404, {"ok": False})
        try:
            size = int(self.headers.get("Content-Length") or 0)
            if size <= 0 or size > 8000:
                raise ValueError
            data = json.loads(self.rfile.read(size).decode("utf-8"))
            if not isinstance(data, dict):
                raise ValueError
        except Exception:
            return self.reply(400, {"ok": False})

        # ловушка для спам-ботов: поле скрыто от людей, заполнить его может только робот
        if str(data.get("hp") or "").strip():
            return self.reply(200, {"ok": True})

        def field(key, limit):
            return html.escape(str(data.get(key) or "").strip())[:limit]

        name = field("name", 80)
        phone = field("phone", 40)
        if len(name) < 2 or len(phone) < 5:
            return self.reply(400, {"ok": False})

        lines = ["<b>Заявка на пробное занятие</b>", "", "Имя: " + name, "Телефон: " + phone]
        age = field("age", 40)
        if age:
            lines.append("Возраст ребёнка: " + age)
        comment = field("comment", 900)
        if comment:
            lines.append("")
            lines.append("Комментарий: " + comment)

        try:
            send("\n".join(lines))
        except Exception:
            return self.reply(502, {"ok": False})
        return self.reply(200, {"ok": True})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8081), Handler).serve_forever()
PY

cat > /etc/systemd/system/shchuka-bot.service <<'UNIT'
[Unit]
Description=Priyom zayavok s sayta v Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
EnvironmentFile=/etc/shchuka-bot.env
ExecStart=/usr/bin/python3 /opt/shchuka-bot/app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable shchuka-bot >/dev/null 2>&1 || true
systemctl restart shchuka-bot
sleep 2
systemctl is-active shchuka-bot

echo "==> Подключаю адрес /api/zayavka в nginx"
install -d -m 755 /etc/nginx/snippets
cat > /etc/nginx/snippets/shchuka-api.conf <<'SNIP'
location = /api/zayavka {
    proxy_pass http://127.0.0.1:8081/api/zayavka;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 30s;
}

# служебные скрипты наружу не отдаём
location ~ ^/(deploy|ssl|telegram)\.sh$ { deny all; }
SNIP

python3 - <<'PY'
path = "/etc/nginx/sites-available/shchuka"
inc = "    include /etc/nginx/snippets/shchuka-api.conf;\n"
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
if any("shchuka-api.conf" in line for line in lines):
    print("    уже подключено")
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

echo "==> Отправляю тестовую заявку"
curl -fsS -X POST "http://127.0.0.1:8081/api/zayavka" \
  -H "Content-Type: application/json" \
  --data '{"name":"Проверка связи","phone":"+7 953 464-96-71","age":"6-7 лет","comment":"Тестовая заявка от настройки сайта."}'
echo

echo
echo "============================================"
echo "  Готово. Заявки уходят в Telegram."
echo
echo "  Проверьте, пришло ли тестовое сообщение."
echo "  Логи: journalctl -u shchuka-bot -n 50"
echo "============================================"
