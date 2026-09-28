#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Круглосуточная проверка сайта «Щука» прямо на сервере.

  monitor.py quick  — лёгкая проверка (каждые 30 минут): пишет в Telegram,
                      только если что-то сломалось или починилось.
  monitor.py daily  — полная проверка раз в день: отправляет тестовую заявку
                      через сайт; её появление в группе и есть отчёт «всё работает».

Что умеет чинить сам: перезапускает веб-сервер и сервис заявок, возвращает
закреплённый адрес api.telegram.org в /etc/hosts.

Токен бота берётся из /etc/shchuka-bot.env и в репозитории не хранится.
Результат последней проверки лежит в /var/www/shchuka/monitor.txt.
"""
import datetime
import fcntl
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

DOMAIN = "xn--80aai0ag2ckyj.xn--p1ai"
WWW = "www." + DOMAIN
HUMAN = "хшщкалуга.рф"
LOCAL_IPS = ["127.0.0.1", "135.106.152.109"]
TG_IP = "149.154.167.220"
ENV_FILE = "/etc/shchuka-bot.env"
STATE_DIR = "/var/lib/shchuka-monitor"
STATE_FILE = STATE_DIR + "/state.json"
LOCK_FILE = STATE_DIR + "/lock"
STATUS_FILE = "/var/www/shchuka/monitor.txt"
CERT_WARN_DAYS = 20
REPEAT_ALERT_SEC = 6 * 3600
MSK = datetime.timezone(datetime.timedelta(hours=3))


def now_msk():
    return datetime.datetime.now(MSK).strftime("%d.%m.%Y %H:%M")


def log(*args):
    print(*args, flush=True)


def sh(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return (p.returncode,
                p.stdout.decode("utf-8", "replace"),
                p.stderr.decode("utf-8", "replace"))
    except Exception as exc:  # noqa
        return 1, "", str(exc)


def http(url, ip=None, method="GET", data=None, nobody=False, timeout=20):
    """Возвращает (код ответа, тело, куда переадресует, ошибка)."""
    host = url.split("/")[2]
    port = "443" if url.startswith("https://") else "80"
    cmd = ["curl", "-sS", "--max-time", str(timeout),
           "-w", "\n%{http_code} %{redirect_url}"]
    if nobody:
        cmd += ["-o", "/dev/null"]
    if ip:
        cmd += ["--resolve", "%s:%s:%s" % (host, port, ip)]
    if method != "GET":
        cmd += ["-X", method]
    if data is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", data]
    cmd.append(url)
    _, out, err = sh(cmd, timeout + 10)
    body, _, tail = out.rpartition("\n")
    parts = tail.split(" ", 1)
    code = int(parts[0]) if parts[0].strip().isdigit() else 0
    redirect = parts[1].strip() if len(parts) > 1 else ""
    return code, body, redirect, err.strip()


def active(service):
    rc, out, _ = sh(["systemctl", "is-active", service], 15)
    return out.strip() == "active"


def hosts_ok():
    try:
        with open("/etc/hosts", encoding="utf-8") as f:
            return any("api.telegram.org" in line and not line.strip().startswith("#")
                       for line in f)
    except OSError:
        return False


def fix_hosts():
    with open("/etc/hosts", "a", encoding="utf-8") as f:
        f.write("\n%s api.telegram.org\n" % TG_IP)


def pick_ip():
    for ip in LOCAL_IPS:
        code = http("https://%s/" % DOMAIN, ip, nobody=True, timeout=10)[0]
        if code:
            return ip
    return LOCAL_IPS[0]


def cert_days(host, ip):
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((ip, 443), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as tls:
                cert = tls.getpeercert()
        left = ssl.cert_time_to_seconds(cert["notAfter"]) - time.time()
        return int(left // 86400), None
    except ssl.SSLCertVerificationError as exc:
        return None, getattr(exc, "verify_message", "") or str(exc)
    except Exception as exc:  # noqa
        return None, str(exc)


def image_urls(body):
    urls = []
    for tag in re.findall(r"<img\b[^>]*>", body, flags=re.I):
        for src in re.findall(r'(?:data-original|data-src|src)\s*=\s*"([^"]+)"', tag):
            if src.startswith("data:"):
                continue
            full = urllib.parse.urljoin("https://%s/" % DOMAIN, src)
            if full not in urls:
                urls.append(full)
    return urls


def check_all():
    """Возвращает (проблемы, предупреждения, что починил, сведения)."""
    problems, warnings, fixes, info = [], [], [], {}

    for svc, label in (("nginx", "веб-сервер"), ("shchuka-bot", "сервис приёма заявок")):
        if not active(svc):
            sh(["systemctl", "restart", svc], 60)
            time.sleep(3)
            if active(svc):
                fixes.append("%s был остановлен — перезапустил, работает" % label)
            else:
                problems.append("Не запускается %s." % label)

    if not hosts_ok():
        try:
            fix_hosts()
            fixes.append("вернул закреплённый адрес Telegram в /etc/hosts")
        except OSError as exc:
            problems.append("Нет закреплённого адреса Telegram в /etc/hosts, "
                            "и вернуть не получилось (%s) — заявки могут не доходить." % exc)

    ip = pick_ip()
    info["ip"] = ip

    code, body, _, err = http("https://%s/" % DOMAIN, ip)
    if code != 200:
        problems.append("Главная страница не открывается (ответ %s %s) — клиенты не видят сайт."
                        % (code or "нет", err[:120]))
        body = ""
    elif "Щука" not in body:
        problems.append("Главная страница открывается, но в ней нет названия школы — "
                        "похоже, на сервере не тот файл.")

    for path, label in (("/policy.html", "Политика"), ("/sveden.html", "Сведения об организации")):
        c = http("https://%s%s" % (DOMAIN, path), ip, nobody=True)[0]
        if c != 200:
            problems.append("Не открывается страница «%s» (ответ %s)." % (label, c or "нет"))

    for host in (DOMAIN, WWW):
        c, _, redir, _ = http("http://%s/" % host, ip, nobody=True)
        if c not in (301, 302, 307, 308) or not redir.startswith("https://"):
            problems.append("Адрес http://%s не переадресует на защищённую версию (ответ %s)."
                            % (host.replace(DOMAIN, HUMAN), c or "нет"))

    min_days = None
    for host in (DOMAIN, WWW):
        days, cerr = cert_days(host, ip)
        name = host.replace(DOMAIN, HUMAN)
        if days is None:
            problems.append("Сертификат для %s не принимается браузерами (%s) — "
                            "клиенты увидят предупреждение «небезопасно»." % (name, cerr[:120]))
            continue
        min_days = days if min_days is None else min(min_days, days)
        if days < 0:
            problems.append("Сертификат для %s просрочен — браузеры не пускают на сайт." % name)
        elif days < CERT_WARN_DAYS:
            warnings.append("Сертификат для %s истекает через %d дн. Если не продлится сам — "
                            "браузеры начнут показывать «небезопасно»." % (name, days))
    info["cert_days"] = min_days

    if body:
        if "calltouch" not in body.lower():
            problems.append("Пропал код коллтрекинга Calltouch — звонки с сайта перестанут "
                            "отслеживаться.")
        broken = []
        urls = image_urls(body)
        for url in urls:
            own = url.split("/")[2] in (DOMAIN, WWW)
            c = http(url, ip if own else None, nobody=True, timeout=25)[0]
            if own and c != 200:
                broken.append(url)
            elif not own and 400 <= c < 600:  # чужой сервер: сбой связи не считаем
                broken.append(url)
        info["images"] = len(urls)
        if broken:
            problems.append("Не открываются картинки (%d шт.): %s"
                            % (len(broken), ", ".join(u.rsplit("/", 1)[-1] for u in broken[:5])))
    return problems, warnings, fixes, info


def send_test_lead(ip, summary):
    payload = json.dumps({
        "name": "Автопроверка сайта",
        "phone": "+7 953 464-96-71",
        "age": "8–10 лет",
        "comment": "Ежедневная проверка с сервера, отвечать не нужно. " + summary,
    }, ensure_ascii=False)

    def attempt():
        c, body, _, err = http("https://%s/api/zayavka" % DOMAIN, ip, "POST", payload, timeout=40)
        try:
            return c == 200 and json.loads(body).get("ok") is True, c, err
        except Exception:  # noqa
            return False, c, err

    ok, c, err = attempt()
    fixed = []
    if not ok:
        if not hosts_ok():
            fix_hosts()
            fixed.append("вернул адрес Telegram в /etc/hosts")
        sh(["systemctl", "restart", "shchuka-bot"], 60)
        fixed.append("перезапустил сервис заявок")
        time.sleep(5)
        ok, c, err = attempt()
    return ok, c, err, fixed


def telegram(text):
    try:
        env = {}
        with open(ENV_FILE, encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    env[k] = v
        url = "https://api.telegram.org/bot%s/sendMessage" % env["TG_TOKEN"]
        data = urllib.parse.urlencode({"chat_id": env["TG_CHAT"], "text": text}).encode()
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=20) as r:
            return r.status == 200
    except Exception as exc:  # noqa
        log("Не удалось отправить сообщение в Telegram:", repr(exc))
        return False


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:  # noqa
        return {}


def save_state(state):
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)


def write_status(lines):
    try:
        with open(STATUS_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(STATUS_FILE, 0o644)
        sh(["chown", "www-data:www-data", STATUS_FILE], 10)
    except OSError as exc:
        log("Не удалось записать monitor.txt:", exc)


def bullets(items):
    return "\n".join("— " + x for x in items)


def run(mode):
    daily = mode == "daily"
    problems, warnings, fixes, info = check_all()
    if problems:  # перепроверяем через минуту, чтобы не поднимать шум из-за секундного сбоя
        log("Найдены проблемы, перепроверяю через минуту:", problems)
        time.sleep(60)
        problems, warnings, fixes2, info = check_all()
        fixes += fixes2

    lead = None
    if daily:
        summary = "Страницы, переадресация, картинки и Calltouch в порядке." if not problems \
            else "Есть проблемы, подробности отдельным сообщением."
        if info.get("cert_days") is not None:
            summary += " Сертификат действует ещё %d дн." % info["cert_days"]
        ok, c, err, lead_fixes = send_test_lead(info["ip"], summary)
        fixes += lead_fixes
        lead = ok
        if not ok:
            problems.append("Заявки с сайта не доходят в Telegram (ответ %s %s). "
                            "Клиенты заполняют форму, а заявка теряется." % (c or "нет", err[:120]))

    state = load_state()
    prev = state.get("problems", [])
    t = time.time()
    messages = []
    if problems:
        if daily or sorted(problems) != sorted(prev) or t - state.get("alert_at", 0) > REPEAT_ALERT_SEC:
            text = "ВНИМАНИЕ: проблема с сайтом %s (%s)\n\n%s" % (HUMAN, now_msk(), bullets(problems))
            if fixes:
                text += "\n\nЧто я уже попробовал:\n" + bullets(fixes)
            messages.append(text)
            state["alert_at"] = t
    else:
        if prev:
            messages.append("Сайт %s снова работает нормально (%s)." % (HUMAN, now_msk()))
        if fixes:
            messages.append("Сайт %s: была неполадка, я её исправил сам (%s).\n\n%s"
                            % (HUMAN, now_msk(), bullets(fixes)))
    if daily and warnings:
        messages.append("Предупреждение по сайту %s:\n\n%s" % (HUMAN, bullets(warnings)))

    for m in messages:
        log(m)
        telegram(m)

    state["problems"] = problems
    state["last_" + mode] = t
    save_state(state)

    status = ["Последняя проверка: %s (%s)" % (now_msk(), "полная" if daily else "быстрая"),
              "Итог: %s" % ("всё в порядке" if not problems else "есть проблемы")]
    if problems:
        status += ["", "Проблемы:"] + ["— " + p for p in problems]
    if warnings:
        status += ["", "Предупреждения:"] + ["— " + w for w in warnings]
    if fixes:
        status += ["", "Исправлено автоматически:"] + ["— " + f for f in fixes]
    status += ["", "Сертификат действует ещё: %s дн." % info.get("cert_days"),
               "Картинок проверено: %s" % info.get("images", 0)]
    if lead is not None:
        status.append("Тестовая заявка: %s" % ("дошла" if lead else "НЕ дошла"))
    last_daily = state.get("last_daily")
    if last_daily:
        status.append("Последняя полная проверка: %s" % datetime.datetime.fromtimestamp(
            last_daily, MSK).strftime("%d.%m.%Y %H:%M"))
    write_status(status)
    log("\n".join(status))
    return 0 if not problems else 1


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "quick"
    if mode not in ("quick", "daily"):
        print("использование: monitor.py quick|daily")
        return 2
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return run(mode)


if __name__ == "__main__":
    sys.exit(main())
