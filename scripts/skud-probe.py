#!/usr/bin/env python3
# skud-probe.py v1.0 — пробник СКУД клуба: HTTP-проверки веб-панелей + служба.
# Ставится НА СЕРВЕР КЛУБА. Конфиг /etc/zabbix-monitor/skud.conf (по строке на
# проверку: URL|Название). Служба: строка "service:itcservice". Метрики в
# textfile node_exporter (порт 9100 уже открыт наружу) -> Prometheus -> MAX.
import subprocess, os

CONF = "/etc/zabbix-monitor/skud.conf"
TF = "/var/lib/prometheus/node-exporter"
os.makedirs(TF, exist_ok=True)
os.makedirs("/etc/zabbix-monitor", exist_ok=True)

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')

out = ["# HELP skud_http_up Доступность HTTP-панелей СКУД", "# TYPE skud_http_up gauge"]
service_lines = []

if os.path.exists(CONF):
    for line in open(CONF, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"): continue
        if line.startswith("service:"):
            service_lines.append(line.split(":", 1)[1].strip()); continue
        url, _, name = line.partition("|")
        url = url.strip(); name = (name or url).strip()
        try:
            r = subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","5",url],
                               capture_output=True, text=True)
            code = (r.stdout or "000").strip()[-3:]
            up = 1 if code.isdigit() and code != "000" and int(code) < 500 else 0
        except Exception:
            up = 0
        out.append(f'skud_http_up{{name="{esc(name)}",url="{esc(url)}"}} {up}')

for svc in service_lines:
    try:
        r = subprocess.run(["systemctl","show",svc,"-p","ActiveState","--value"],
                           capture_output=True, text=True)
        up = 1 if r.stdout.strip() == "active" else 0
    except Exception:
        up = 0
    out.append(f'skud_service_up{{name="{esc(svc)}"}} {up}')

if len(out) > 2 or service_lines:
    out.insert(2, "# HELP skud_service_up Службы СКУД")
    out.insert(3, "# TYPE skud_service_up gauge")
tmp = f"{TF}/skud.prom.tmp"
open(tmp, "w").write("\n".join(out) + "\n")
os.replace(tmp, f"{TF}/skud.prom")
