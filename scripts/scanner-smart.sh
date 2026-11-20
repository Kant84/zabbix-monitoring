#!/bin/bash
# scanner-smart.sh v1.0 — обнаружение smartctl_exporter (порт 9633)
# Конфиг /etc/zabbix-monitor/smart.conf: одна запись в строке —
#   подсеть офиса без последнего октета (192.168.88) или полный IP клуба (5.227.70.150)
# Результат: /etc/prometheus/file-sd/office/smart.json (Prometheus подхватит за 30 сек)
set -u
CONF="${SMART_CONF:-/etc/zabbix-monitor/smart.conf}"
OUT="/etc/prometheus/file-sd/office/smart.json"
LOG="/var/log/zabbix/scanner-smart.log"
mkdir -p "$(dirname "$OUT")" /var/log/zabbix
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -f "$CONF" ] || { log "ERROR: нет конфига $CONF"; exit 1; }

# Формат smart.conf: подсеть (192.168.88) или полный IP; у клубов можно
# указать название для лейбла club (тревоги будут с именем клуба):
#   192.168.88
#   5.227.70.150=Физра Н.Новгород
found=$(mktemp)
while read -r net; do
    case "$net" in ''|\#*) continue;; esac
    name=""
    ip="$net"
    case "$net" in *=*) ip="${net%%=*}"; name="${net#*=}";; esac
    if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if nc -z -w1 "$ip" 9633 2>/dev/null; then
            echo "${ip}:9633|$name" >> "$found"
        fi
    else
        seq 1 254 | xargs -P 64 -I{} sh -c "nc -z -w1 ${net}.{} 9633 2>/dev/null && echo ${net}.{}:9633|" >> "$found"
    fi
done < "$CONF"
sort -u "$found" -o "$found"

python3 - "$found" "$OUT" <<'PYEOF'
import json, sys
plain, clubs = [], {}
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    tgt, _, name = l.partition("|")
    if name: clubs.setdefault(name, []).append(tgt)
    else: plain.append(tgt)
groups = []
if plain:
    groups.append({"targets": plain, "labels": {"job":"smartctl","location_type":"office","env":"office"}})
for name, tgts in clubs.items():
    groups.append({"targets": tgts, "labels": {"job":"smartctl","location_type":"branch","env":"club","club":name}})
json.dump(groups, open(sys.argv[2],"w"), indent=1)
PYEOF

chown prometheus:prometheus "$OUT" 2>/dev/null || true
log "found $(wc -l < "$found") smartctl targets"
rm -f "$found"
