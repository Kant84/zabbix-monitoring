#!/bin/bash
# scanner-branches.sh v4.2 — обнаружение серверов филиалов → file-sd Prometheus
# Формат /etc/zabbix-monitor/branches.conf:
#   <city> <подсеть-без-последнего-октета> <region>     (пример: msk 10.50.1 moscow)
# Каждый цикл: пингует подсеть, ищет node_exporter (9100), пишет
# /etc/prometheus/file-sd/branches/<city>.json. Пустой результат → файл удаляется
# (баг v4.1: писался "targets": [""] и устройство висело в мониторинге фантомом).
set -u
FILE_SD_DIR="/etc/prometheus/file-sd/branches"
BRANCHES_CONF="${BRANCHES_CONF:-/etc/zabbix-monitor/branches.conf}"
LOG="/var/log/zabbix/scanner-branches.log"
mkdir -p "$FILE_SD_DIR" /var/log/zabbix
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -f "$BRANCHES_CONF" ] || { log "ERROR: нет конфига $BRANCHES_CONF"; exit 1; }

# Удаляем json филиалов, которых больше нет в конфиге
declare -A keep
while read -r city subnet region; do
    case "$city" in ''|\#*) continue;; esac
    keep[$city]=1
done < "$BRANCHES_CONF"
for f in "$FILE_SD_DIR"/*.json; do
    [ -e "$f" ] || continue
    c=$(basename "$f" .json)
    [ -n "${keep[$c]:-}" ] || { rm -f "$f"; log "removed stale $f"; }
done

while read -r city subnet region; do
    case "$city" in ''|\#*) continue;; esac
    targets=()
    for i in $(seq 1 254); do
        ip="${subnet}.${i}"
        if ping -c1 -W1 "$ip" >/dev/null 2>&1 && nc -z -w1 "$ip" 9100 >/dev/null 2>&1; then
            targets+=("\"${ip}:9100\"")
        fi
    done
    if [ "${#targets[@]}" -eq 0 ]; then
        rm -f "$FILE_SD_DIR/${city}.json"
        log "$city: живых хостов не найдено, json удалён"
        continue
    fi
    printf '[\n  {\n    "targets": [%s],\n    "labels": {\n      "city": "%s",\n      "region": "%s",\n      "env": "production",\n      "group": "branch-%s"\n    }\n  }\n]\n' \
        "$(IFS=,; echo "${targets[*]}")" "$city" "$region" "$city" > "$FILE_SD_DIR/${city}.json"
    chown prometheus:prometheus "$FILE_SD_DIR/${city}.json" 2>/dev/null || true
    log "$city: найдено ${#targets[@]} хостов"
done < "$BRANCHES_CONF"
