#!/bin/bash
# =============================================================================
# club-report.sh v1.1 — ежемесячный отчёт по клубам В MAX ФАЙЛОМ (md) + сводка.
# Источники: Zabbix API (группа "Clubs"), Prometheus API (30 дней),
# MAX Bot API (uploads -> file attachment). Запуск: club-report.timer (1-е, 09:00).
# =============================================================================
set -e
[ -f /etc/default/max-webhook-server ] || { echo "Нет /etc/default/max-webhook-server"; exit 1; }

python3 <<'PYEOF'
import json, urllib.request, urllib.parse, os, time, datetime, subprocess, re

ZAPI = "http://localhost/zabbix/api_jsonrpc.php"
PROM = "http://localhost:9090"
env = {}
for line in open("/etc/default/max-webhook-server"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line: continue
    k, v = line.split("=", 1)
    env[k.strip()] = v.strip().strip('"').strip("'")
TOKEN = env["MAX_BOT_TOKEN"]; CHAT = env["MAX_CHAT_ID"]
if not TOKEN or TOKEN.startswith("YOUR_"): raise SystemExit("Токен MAX не задан")
BASE = "https://platform-api2.max.ru"   # рекомендованный домен (dev.max.ru)

def post(url, payload, auth=None):
    headers = {"Content-Type": "application/json"}
    if auth: headers["Authorization"] = "Bearer " + auth
    r = urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers))
    return json.load(r)

now = int(time.time()); start = now - 30*86400
MONTH_RU = {1:"Январь",2:"Февраль",3:"Март",4:"Апрель",5:"Май",6:"Июнь",7:"Июль",8:"Август",9:"Сентябрь",10:"Октябрь",11:"Ноябрь",12:"Декабрь"}
d = datetime.datetime.now(); MONTH = f"{MONTH_RU[d.month]} {d.year}"; YM = d.strftime("%Y-%m")

def q(expr):
    u = f"{PROM}/api/v1/query?query={urllib.parse.quote(expr)}"
    return json.load(urllib.request.urlopen(u))["data"]["result"]

def qrange(expr, step=3600):
    u = (f"{PROM}/api/v1/query_range?query={urllib.parse.quote(expr)}&start={start}&end={now}&step={step}")
    r = json.load(urllib.request.urlopen(u))["data"]["result"]
    return [float(v[1]) for s in r for v in s["values"] if v[1] not in ("NaN","+Inf","-Inf")]

def stat(vals): return (round(sum(vals)/len(vals),1), round(max(vals),1)) if vals else (None,None)
def s_sum(expr):
    r = q(expr); return round(sum(float(x["value"][1]) for x in r), 1) if r else 0
def fmt(x): return "—" if x is None else str(x)

def send_text(text):
    post(f"{BASE}/messages?chat_id={CHAT}", {"text": text}, auth=TOKEN)

def upload_and_send(path, caption):
    r = subprocess.run(["curl","-s","-X","POST",f"{BASE}/uploads?type=file",
                        "-H",f"Authorization: {TOKEN}"], capture_output=True, text=True)
    up = json.loads(r.stdout); url = up["url"]
    r = subprocess.run(["curl","-s","-F",f"data=@{path}", url], capture_output=True, text=True)
    tok = None
    try: tok = json.loads(r.stdout).get("token")
    except Exception: tok = r.stdout.strip() or None
    if not tok: raise RuntimeError("не получен токен файла: " + r.stdout[:200])
    time.sleep(3)
    for attempt in range(4):
        try:
            post(f"{BASE}/messages?chat_id={CHAT}", {"text": caption, "attachments":[{"type":"file","payload":{"token":tok}}]}, auth=TOKEN)
            return True
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:200]
            if "attachment.not.ready" in body or "not.processed" in body: time.sleep(5*(attempt+1)); continue
            raise
    raise RuntimeError("файл не обработался MAX после 4 попыток")

tok = post(ZAPI, {"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1})["result"]
gid = post(ZAPI, {"jsonrpc":"2.0","method":"hostgroup.get","params":{"filter":{"name":"Clubs"}},"auth":tok,"id":2})["result"][0]["groupid"]
hosts = post(ZAPI, {"jsonrpc":"2.0","method":"host.get","params":{"groupids":[gid],"selectInterfaces":["ip"],"output":["host","name"]},"auth":tok,"id":3})["result"]

for h in hosts:
    name = h.get("name") or h["host"]; ip = h["interfaces"][0]["ip"]; inst = ip + ":9100"
    up = qrange(f'up{{instance="{inst}"}}')
    avail = round(100*sum(up)/len(up),1) if up else None
    cpu = stat(qrange(f'100 - avg(irate(node_cpu_seconds_total{{instance="{inst}",mode="idle"}}[5m])) * 100'))
    ram = stat(qrange(f'100*(1-node_memory_MemAvailable_bytes{{instance="{inst}"}}/node_memory_MemTotal_bytes{{instance="{inst}"}}))'))
    dsk = stat(qrange(f'100*(1-node_filesystem_avail_bytes{{instance="{inst}",mountpoint="/",fstype!~"tmpfs|overlay"}}/node_filesystem_size_bytes{{instance="{inst}",mountpoint="/",fstype!~"tmpfs|overlay"}}))'))
    tmax = stat(qrange(f'smartctl_device_temperature{{instance="{ip}:9633"}}'))
    wear = qrange(f'smartctl_device_percentage_used{{instance="{ip}:9633"}}')
    smart = qrange(f'smartctl_device_smart_status{{instance="{ip}:9633"}}')
    fails = s_sum(f'sum(increase(ssh_failed_logins_total{{instance="{inst}",ip!~"10\\\\.10\\\\.1\\\\..*|192\\\\.168\\\\..*|127\\\\..*"}}[30d]))')
    oks = s_sum(f'sum(increase(ssh_success_logins_total{{instance="{inst}"}}[30d]))')
    srv = s_sum(f'sum(max_over_time(node_systemd_unit_state{{instance="{inst}",state="failed"}}[30d]))')

    report = (f"# Отчёт по клубу: {name} ({ip})\n## Период: {MONTH}\n\n"
        f"- Доступность сервера: {fmt(avail)}%\n"
        f"- CPU: ср {fmt(cpu[0])}% / пик {fmt(cpu[1])}%\n"
        f"- RAM: ср {fmt(ram[0])}% / пик {fmt(ram[1])}%\n"
        f"- Диск `/`: ср {fmt(dsk[0])}% / пик {fmt(dsk[1])}% занято\n"
        f"- SSD SMART: {'OK' if smart and smart[-1]==1 else 'ПРОВЕРИТЬ'}; износ {fmt(round(wear[-1],1) if wear else None)}%; t° max {fmt(tmax[1])}\n"
        f"- Безопасность: подборов SSH (чужие IP) {int(fails)}, успешных входов {int(oks)}\n"
        f"- Службы failed (пик за месяц): {int(srv)}\n")
    path = f"/tmp/otchet-{h['host']}-{YM}.md"
    open(path, "w", encoding="utf-8").write(report)
    caption = (f"📊 **{name}** — отчёт за {MONTH} (файл выше)\n"
               f"⏱ {fmt(avail)}% | 🖥 CPU пик {fmt(cpu[1])}% | 🛡 подборов {int(fails)}")
    upload_and_send(path, caption)
    print("отчёт-файл отправлен:", name)
PYEOF
