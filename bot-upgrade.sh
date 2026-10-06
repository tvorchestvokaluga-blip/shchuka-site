#!/usr/bin/env bash
# Обновление приёма заявок: сохранение в файл + повторы + дубль на почту.
# Запуск на сервере из-под root:
#   curl -fsSL -o /tmp/bot-upgrade.sh raw.githubusercontent.com/tvorchestvokaluga-blip/shchuka-site/main/bot-upgrade.sh
#   bash /tmp/bot-upgrade.sh                                  — только файл + повторы в Telegram
#   bash /tmp/bot-upgrade.sh АДРЕС_GMAIL ПАРОЛЬ_ПРИЛОЖЕНИЯ     — плюс дубль на почту
# Пароль приложения Gmail в репозиторий не попадает — он пишется только в
# /etc/shchuka-bot.env (права 600). Токен Telegram не трогаем.
set -euo pipefail
MAIL="${1:-}"
PASS="$(printf '%s' "${2:-}" | tr -d ' ')"

cp -a /opt/shchuka-bot/app.py "/opt/shchuka-bot/app.py.bak.$(date +%s)"
echo "==> Ставлю новую версию сервиса"
cat > /opt/shchuka-bot/app.py <<'PY'
# -*- coding: utf-8 -*-
"""Приём заявок с сайта: сохраняем в файл, шлём в Telegram и на почту, повторяем до успеха."""
import html
import json
import os
import smtplib
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("TG_TOKEN", "")
CHAT = os.environ.get("TG_CHAT", "")
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "465"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
MAIL_TO = os.environ.get("MAIL_TO", "")
STATE = os.environ.get("STATE_DIR", "/var/lib/shchuka-bot")
QUEUE = os.path.join(STATE, "queue")
DONE = os.path.join(STATE, "done")
PORT = int(os.environ.get("PORT", "8081"))
RETRY_SECONDS = int(os.environ.get("RETRY_SECONDS", "60"))
LATE_SECONDS = 300

TG_ON = bool(TOKEN and CHAT)
MAIL_ON = bool(SMTP_USER and SMTP_PASS and MAIL_TO)
wake = threading.Event()
lock = threading.Lock()


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def send_telegram(text):
    api = "https://api.telegram.org/bot%s/sendMessage" % TOKEN
    body = urllib.parse.urlencode(
        {"chat_id": CHAT, "text": text, "parse_mode": "HTML"}
    ).encode("utf-8")
    with urllib.request.urlopen(urllib.request.Request(api, data=body), timeout=15) as r:
        if r.status != 200:
            raise RuntimeError("telegram status %s" % r.status)


def send_mail(subject, text):
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_USER
    msg["To"] = MAIL_TO
    msg.set_content(text)
    # DNS на сервере иногда отдаёт только IPv6, а маршрута нет — идём по IPv4.
    ip = socket.getaddrinfo(SMTP_HOST, SMTP_PORT, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    ctx = ssl.create_default_context()

    class V4SSL(smtplib.SMTP_SSL):
        def _get_socket(self, host, port, timeout):
            raw = socket.create_connection((ip, port), timeout)
            return ctx.wrap_socket(raw, server_hostname=SMTP_HOST)

    with V4SSL(SMTP_HOST, SMTP_PORT, timeout=20, context=ctx) as s:
        s.login(SMTP_USER, SMTP_PASS)
        s.send_message(msg)


def plain(item):
    return item["plain"]


def deliver(path):
    """Пробует доставить заявку по каждому ещё не доставленному каналу."""
    with open(path, encoding="utf-8") as f:
        item = json.load(f)
    late = time.time() - item["created"] > LATE_SECONDS
    stamp = time.strftime("%d.%m %H:%M", time.localtime(item["created"]))
    prefix = ("<i>Заявка от %s, дошла с задержкой</i>\n\n" % stamp) if late else ""
    changed = False
    if TG_ON and not item.get("tg"):
        try:
            send_telegram(prefix + item["html"])
            item["tg"] = True
            changed = True
        except Exception as exc:
            item["tg_err"] = repr(exc)[:200]
            log("Telegram send failed: %r" % (exc,))
    if MAIL_ON and not item.get("mail"):
        try:
            send_mail("Заявка с сайта Щука: " + item["name"], item["plain"])
            item["mail"] = True
            changed = True
        except Exception as exc:
            item["mail_err"] = repr(exc)[:200]
            log("Mail send failed: %r" % (exc,))
    item["attempts"] = item.get("attempts", 0) + 1
    ok_tg = item.get("tg") or not TG_ON
    ok_mail = item.get("mail") or not MAIL_ON
    # Заявка считается доставленной, если дошла хотя бы одним каналом, и по остальным
    # продолжаем повторять до успеха.
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(item, f, ensure_ascii=False)
    os.replace(tmp, path)
    if ok_tg and ok_mail:
        os.replace(path, os.path.join(DONE, os.path.basename(path)))
    return changed


def worker():
    while True:
        wake.wait(RETRY_SECONDS)
        wake.clear()
        with lock:
            for name in sorted(os.listdir(QUEUE)):
                if name.endswith(".json"):
                    try:
                        deliver(os.path.join(QUEUE, name))
                    except Exception as exc:
                        log("deliver error %s: %r" % (name, exc))


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

        suspicious = bool(str(data.get("hp") or "").strip())

        def raw(key, limit):
            return str(data.get(key) or "").strip()[:limit]

        name, phone = raw("name", 80), raw("phone", 40)
        if len(name) < 2 or len(phone) < 5:
            return self.reply(400, {"ok": False})
        age, comment = raw("age", 40), raw("comment", 900)

        def build(esc):
            title = "Заявка на пробное занятие"
            if suspicious:
                title += "\n(похоже на автозаполнение или бота — проверьте телефон)"
            lines = [title, "", "Имя: " + esc(name), "Телефон: " + esc(phone)]
            if age:
                lines.append("Возраст ребёнка: " + esc(age))
            if comment:
                lines += ["", "Комментарий: " + esc(comment)]
            return "\n".join(lines)

        item = {
            "created": time.time(),
            "name": name,
            "html": build(html.escape).replace("Заявка на пробное занятие", "<b>Заявка на пробное занятие</b>", 1),
            "plain": build(lambda s: s),
        }
        try:
            os.makedirs(QUEUE, exist_ok=True)
            fname = "%d-%s.json" % (int(item["created"]), uuid.uuid4().hex[:8])
            path = os.path.join(QUEUE, fname)
            with open(path + ".tmp", "w", encoding="utf-8") as f:
                json.dump(item, f, ensure_ascii=False)
            os.replace(path + ".tmp", path)
        except Exception as exc:
            log("save failed: %r" % (exc,))
            return self.reply(500, {"ok": False})
        wake.set()
        return self.reply(200, {"ok": True})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    os.makedirs(QUEUE, exist_ok=True)
    os.makedirs(DONE, exist_ok=True)
    log("start telegram=%s mail=%s" % (TG_ON, MAIL_ON))
    threading.Thread(target=worker, daemon=True).start()
    wake.set()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY

echo "==> Прописываю почту"
if [ -n "$MAIL" ] && [ -n "$PASS" ]; then
sed -i '/^SMTP_\|^MAIL_TO=/d' /etc/shchuka-bot.env
{
  echo "SMTP_HOST=smtp.gmail.com"
  echo "SMTP_PORT=465"
  echo "SMTP_USER=${MAIL}"
  echo "SMTP_PASS=${PASS}"
  echo "MAIL_TO=${MAIL}"
} >> /etc/shchuka-bot.env
else
  echo "    почта не указана — работаем только с Telegram"
fi
chmod 600 /etc/shchuka-bot.env

echo "==> Папка для очереди заявок"
install -d /etc/systemd/system/shchuka-bot.service.d
cat > /etc/systemd/system/shchuka-bot.service.d/state.conf <<'UNIT'
[Service]
StateDirectory=shchuka-bot
UNIT
systemctl daemon-reload
systemctl restart shchuka-bot
sleep 3
systemctl is-active shchuka-bot

echo "==> Тестовая заявка"
curl -fsS -X POST http://127.0.0.1:8081/api/zayavka -H "Content-Type: application/json" \
  --data '{"name":"Проверка дубля","phone":"+7 953 464-96-71","age":"8-10 лет","comment":"Тест нового приёма заявок. Должно прийти в Telegram."}'
echo
sleep 8
echo "Ждут отправки: $(ls /var/lib/shchuka-bot/queue | wc -l)"
journalctl -u shchuka-bot -n 5 --no-pager | cut -c 1-110
echo "Готово. Проверьте Telegram и почту."
