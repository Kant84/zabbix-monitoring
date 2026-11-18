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

found=$(mktemp)
while read -r net; do
    case "$net" in ''|\#*) continue;; esac
    if echo "$net" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        # Полный IP (клуб и т.п.)
        nc -z -w1 "$net" 9633 2>/dev/null && echo "${net}:9633" >> "$found"
    else
        # Подсеть (офис)
        seq 1 254 | xargs -P 64 -I{} sh -c "nc -z -w1 ${net}.{} 9633 2>/dev/null && echo ${net}.{}:9633" >> "$found"
    fi
done < "$CONF"
sort -u "$found" -o "$found"

python3 - "$found" "$OUT" <<'PYEOF'
import json, sys
targets=[l.strip() for l in open(sys.argv[1]) if l.strip()]
data=[{"targets": targets, "labels": {"job":"smartctl","location_type":"office","env":"office"}}] if targets else []
json.dump(data, open(sys.argv[2],"w"), indent=1)
PYEOF

chown prometheus:prometheus "$OUT" 2>/dev/null || true
log "found $(wc -l < "$found") smartctl targets"
rm -f "$found"
