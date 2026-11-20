#!/usr/bin/env python3
# auth-metrics.py v2 — SSH-события -> node_exporter textfile.
# Источник: /var/log/auth.log (инкрементально) или journald _COMM=sshd (полный
# пересчёт, если auth.log отсутствует). Атомарная запись, экранирование меток.
import re, os, json, subprocess
TF = "/var/lib/prometheus/node-exporter"
STATE = "/var/lib/node_exporter/.auth_state.json"
os.makedirs(TF, exist_ok=True)
LOG = "/var/log/auth.log"
journal_mode = not os.path.exists(LOG)
if journal_mode:
    lines = subprocess.run(["journalctl","_COMM=sshd","--no-pager","-q"],
                           capture_output=True, text=True).stdout.splitlines()
    state = {"last": 0, "F": {}, "O": {}}
else:
    lines = open(LOG, errors="replace").read().splitlines()
    state = {"last": 0, "F": {}, "O": {}}
    try: state = json.load(open(STATE))
    except Exception: pass
last, total = state["last"], len(lines)
if last > total: last = 0
F, O = ({}, {}) if journal_mode else (state["F"], state["O"])
pat_fail = re.compile(r"sshd.*Failed password for (?:invalid user )?(\S+) from (\S+)")
pat_ok   = re.compile(r"sshd.*Accepted (?:password|publickey) for (\S+) from (\S+)")
for ln in (lines if journal_mode else lines[last:]):
    m = pat_fail.search(ln) or pat_ok.search(ln)
    if not m: continue
    u, ip = m.group(1), m.group(2)
    d = F if "Failed" in ln else O
    d[f"{ip}|{u}"] = d.get(f"{ip}|{u}", 0) + 1
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
out = ["# HELP ssh_failed_logins_total Неудачные SSH-попытки", "# TYPE ssh_failed_logins_total counter"]
for k, v in F.items():
    ip, u = k.split("|", 1); out.append(f'ssh_failed_logins_total{{ip="{esc(ip)}",user="{esc(u)}"}} {v}')
out += ["# HELP ssh_success_logins_total Успешные SSH-входы", "# TYPE ssh_success_logins_total counter"]
for k, v in O.items():
    ip, u = k.split("|", 1); out.append(f'ssh_success_logins_total{{ip="{esc(ip)}",user="{esc(u)}"}} {v}')
tmp = f"{TF}/auth.prom.tmp"; open(tmp, "w").write("\n".join(out) + "\n"); os.replace(tmp, f"{TF}/auth.prom")
os.makedirs(os.path.dirname(STATE), exist_ok=True)
json.dump({"last": total, "F": F, "O": O}, open(STATE, "w"))
