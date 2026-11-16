#!/bin/bash
# Разовая регистрация известных хостов в Zabbix через API
# Список задаётся здесь или переносится в конфиг. Шаблон: Linux by Zabbix agent active.
set -e

ZABBIX_URL="${ZABBIX_URL:-http://localhost/zabbix/api_jsonrpc.php}"
ZABBIX_USER="${ZABBIX_USER:-Admin}"
ZABBIX_PASS="${ZABBIX_PASS:-zabbix}"
# Проверьте ID своего шаблона (см. scanner-branches.sh)
LINUX_TEMPLATE_ID="${LINUX_TEMPLATE_ID:-10343}"

TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"$ZABBIX_USER\",\"password\":\"$ZABBIX_PASS\"},\"id\":1}" \
  "$ZABBIX_URL" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

# host:ip — ЗАМЕНИТЕ на реальные хосты или заполните из branches.conf
HOSTS=(
  "msk-1c-01:CHANGE_ME"
  "msk-docker-01:CHANGE_ME"
  "spb-1c-01:CHANGE_ME"
  "kzn-1c-01:CHANGE_ME"
  "nsk-1c-01:CHANGE_ME"
)

for entry in "${HOSTS[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  [ "$ip" = "CHANGE_ME" ] && { echo "SKIP $host (нет IP — замените CHANGE_ME)"; continue; }

  exists=$(curl -s -X POST -H 'Content-Type: application/json' -d "{
    \"jsonrpc\":\"2.0\",\"method\":\"host.get\",
    \"params\":{\"filter\":{\"host\":\"$host\"},\"output\":[\"hostid\"]},
    \"auth\":\"$TOKEN\",\"id\":1}" "$ZABBIX_URL" | grep -c '"hostid"' || true)

  if [ "$exists" -gt 0 ]; then
    echo "EXISTS: $host"; continue
  fi

  echo "Adding $host ($ip)..."
  curl -s -X POST -H 'Content-Type: application/json' -d "{
    \"jsonrpc\":\"2.0\",
    \"method\":\"host.create\",
    \"params\":{
      \"host\":\"$host\",
      \"interfaces\":[{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"$ip\",\"dns\":\"\",\"port\":\"10050\"}],
      \"groups\":[{\"groupid\":\"2\"}],
      \"templates\":[{\"templateid\":\"$LINUX_TEMPLATE_ID\"}]
    },
    \"auth\":\"$TOKEN\",
    \"id\":1
  }" "$ZABBIX_URL" | python3 -m json.tool | grep -E 'hostids|error' || true
done
