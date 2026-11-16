#!/bin/bash
# Сканер филиалов: обновляет file-sd JSON для Prometheus + регистрирует хосты в Zabbix.
# Подсети НЕ зашиты в коде — читаются из /etc/zabbix-monitor/branches.conf:
#   <city> <подсеть-без-последнего-октета> <region>
set -e

LOG="/var/log/zabbix/scanner-branches.log"
FILE_SD_DIR="/etc/prometheus/file-sd/branches"
BRANCHES_CONF="${BRANCHES_CONF:-/etc/zabbix-monitor/branches.conf}"
ZABBIX_URL="${ZABBIX_URL:-http://localhost/zabbix/api_jsonrpc.php}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASS="${ZABBIX_PASS:-zabbix}"
# Шаблон "Linux by Zabbix agent active". Проверьте свой ID:
#   curl ... -d '{"method":"template.get","params":{"filter":{"host":"Linux by Zabbix agent active"}}}'
LINUX_TEMPLATE_ID="${LINUX_TEMPLATE_ID:-10343}"

log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG"; }

if [ ! -f "$BRANCHES_CONF" ]; then
    log "ERROR: нет конфига $BRANCHES_CONF"; exit 1
fi

mkdir -p "$FILE_SD_DIR"

TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
  "$ZABBIX_URL" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

# Проверка существования шаблона
tpl_ok=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
  \"jsonrpc\":\"2.0\",\"method\":\"template.get\",
  \"params\":{\"templateids\":[\"$LINUX_TEMPLATE_ID\"],\"output\":[\"templateid\"]},
  \"auth\":\"$TOKEN\",\"id\":1}" "$ZABBIX_URL" | grep -c '"templateid"' || true)
if [ "$tpl_ok" -eq 0 ]; then
    log "ERROR: шаблон $LINUX_TEMPLATE_ID не найден. Узнайте ID: template.get filter host='Linux by Zabbix agent active'"
    exit 1
fi

discover_in_subnet() {
    local subnet="$1"
    for i in $(seq 1 254); do
        local ip="${subnet}.${i}"
        ping -c1 -W1 "$ip" >/dev/null 2>&1 || continue
        nc -z -w1 "$ip" 9100 2>/dev/null && echo "${ip}:9100"
    done
}

register_in_zabbix() {
    local ip="$1" hostname="$2"
    local exists
    exists=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
      \"jsonrpc\":\"2.0\",\"method\":\"host.get\",
      \"params\":{\"filter\":{\"host\":\"$hostname\"},\"output\":[\"hostid\"]},
      \"auth\":\"$TOKEN\",\"id\":1}" "$ZABBIX_URL" | grep -c '"hostid"' || true)
    [ "$exists" -gt 0 ] && return 0
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
}

log "=== Branch scan started ==="

while read -r city subnet region; do
    [[ "$city" =~ ^#.*$ || -z "$city" ]] && continue
    log "Scanning $city ($subnet.0/24)..."

    targets=()
    while IFS= read -r t; do
        [ -n "$t" ] && targets+=("$t")
    done < <(discover_in_subnet "$subnet")

    json_targets=$(printf '"%s",' "${targets[@]}" 2>/dev/null | sed 's/,$//')
    cat > "$FILE_SD_DIR/${city}.json" <<EOF
[
  {
    "targets": [${json_targets}],
    "labels": {
      "city": "${city}",
      "region": "${region}",
      "env": "production",
      "group": "branch-${city}"
    }
  }
]
EOF
    log "  $city: ${#targets[@]} targets"

    for t in "${targets[@]}"; do
        ip="${t%%:*}"
        register_in_zabbix "$ip" "branch-${city}-${ip##*.}"
    done
done < "$BRANCHES_CONF"

log "=== Branch scan completed ==="
