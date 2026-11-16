#!/bin/bash
# Сканер офисного LAN: ARP + ping sweep + проверка портов 9100/10050.
# Обновляет /etc/prometheus/file-sd/office/lan.json и регистрирует хосты в Zabbix.
# Подсеть задаётся в /etc/zabbix-monitor/office.conf: OFFICE_SUBNET=192.168.1
set -e

LOG="/var/log/zabbix/scanner-office.log"
FILE_SD="/etc/prometheus/file-sd/office/lan.json"
OFFICE_CONF="${OFFICE_CONF:-/etc/zabbix-monitor/office.conf}"
ZABBIX_URL="${ZABBIX_URL:-http://localhost/zabbix/api_jsonrpc.php}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASS="${ZABBIX_PASS:-zabbix}"
LINUX_TEMPLATE_ID="${LINUX_TEMPLATE_ID:-10343}"

log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG"; }

if [ -f "$OFFICE_CONF" ]; then
    # shellcheck disable=SC1090
    . "$OFFICE_CONF"
fi
OFFICE_SUBNET="${OFFICE_SUBNET:-10.100.0}"

mkdir -p "$(dirname "$FILE_SD")"

TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
  "$ZABBIX_URL" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

log "=== Office scan: $OFFICE_SUBNET.0/24 ==="

declare -A FOUND

# Уже известные соседи (ARP)
while read -r ip; do
    FOUND["$ip"]=1
done < <(ip neigh show | awk -v s="$OFFICE_SUBNET" '$1 ~ "^"s"\\." && $4 != "FAILED" {print $1}')

# Ping sweep — новые машины
for i in $(seq 1 254); do
    ip="${OFFICE_SUBNET}.${i}"
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && FOUND["$ip"]=1
done

# Фильтр: только с node_exporter (9100)
TARGETS=()
for ip in $(printf '%s\n' "${!FOUND[@]}" | sort -t. -k4 -n); do
    if nc -z -w1 "$ip" 9100 2>/dev/null; then
        TARGETS+=("${ip}:9100")
        log "  + $ip (node_exporter)"
    fi
done

json_targets=$(printf '"%s",' "${TARGETS[@]}" 2>/dev/null | sed 's/,$//')
cat > "$FILE_SD" <<EOF
[
  {
    "targets": [${json_targets}],
    "labels": {
      "location_type": "office",
      "env": "office",
      "network": "${OFFICE_SUBNET}.0/24"
    }
  }
]
EOF
log "Office: ${#TARGETS[@]} targets -> $FILE_SD"

# Регистрация в Zabbix (хосты с Zabbix Agent, порт 10050)
for ip in $(printf '%s\n' "${!FOUND[@]}" | sort -t. -k4 -n); do
    nc -z -w1 "$ip" 10050 2>/dev/null || continue
    hostname="office-${ip##*.}"
    exists=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
      \"jsonrpc\":\"2.0\",\"method\":\"host.get\",
      \"params\":{\"filter\":{\"host\":\"$hostname\"},\"output\":[\"hostid\"]},
      \"auth\":\"$TOKEN\",\"id\":1}" "$ZABBIX_URL" | grep -c '"hostid"' || true)
    if [ "$exists" -eq 0 ]; then
        curl -s -X POST -H 'Content-Type: application/json' -d "{
          \"jsonrpc\":\"2.0\",\"method\":\"host.create\",
          \"params\":{
            \"host\":\"$hostname\",
            \"interfaces\":[{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"$ip\",\"dns\":\"\",\"port\":\"10050\"}],
            \"groups\":[{\"groupid\":\"2\"}],
            \"templates\":[{\"templateid\":\"$LINUX_TEMPLATE_ID\"}]
          },
          \"auth\":\"$TOKEN\",\"id\":1}" "$ZABBIX_URL" >/dev/null
        log "  Registered in Zabbix: $hostname ($ip)"
    fi
done

log "=== Office scan completed ==="
