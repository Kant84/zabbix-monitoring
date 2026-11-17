#!/bin/bash
# =============================================================================
# add-club-host.sh v4.2.2 — регистрация клубного сервера в Zabbix через API
# Выполняется НА СЕРВЕРЕ МОНИТОРИНГА (локальный Zabbix API).
#
#   ./add-club-host.sh --name club-nn-fizra --ip 5.227.70.150
#   ./add-club-host.sh --name club-ekb-01 --psk <64-hex> [--group Clubs]
#
# --ip: публичный IP клубного сервера (passive-проверки: сервер сам ходит к агенту
#       на 10050; NAT/пробросов в офисе НЕ требуется). Без --ip — 127.0.0.1
#       (только active-режим, нужен проброс 10051 на офисный Mikrotik).
#
# Создаёт хост с шаблоном «Linux by Zabbix agent active», шифрованием PSK
# (tls_connect=tls_accept=PSK) и генерирует PSK-ключ. Ключ нужен при установке
# агента на клубном сервере: install-agent.sh --active --psk <ключ>.
# Требование: agent на клубе настроен на ServerActive=<белый IP офиса>:10051
# (Mikrotik: dst-nat TCP 10051 -> 192.168.88.36).
# =============================================================================
set -e
NAME=""; PSK=""; GROUP="Clubs"; IP="127.0.0.1"
while [ $# -gt 0 ]; do
    case "$1" in
        --name)  NAME="$2";  shift 2;;
        --psk)   PSK="$2";   shift 2;;
        --group) GROUP="$2"; shift 2;;
        --ip)    IP="$2";    shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ -n "$NAME" ] || { echo "Укажите --name club-<city>-<short>"; exit 1; }

ZAPI="http://localhost/zabbix/api_jsonrpc.php"
ZUSER="${ZABBIX_USER:-Admin}"
ZPASS="${ZABBIX_PASS:-zabbix}"

api() { # api <method> <params-json>
    curl -s -X POST -H 'Content-Type: application/json' -d "$2" "$ZAPI"
}
[ -z "$PSK" ] && PSK=$(openssl rand -hex 32)

TOKEN=$(api user.login "$(printf '{"jsonrpc":"2.0","method":"user.login","params":{"username":"%s","password":"%s"},"id":1}' "$ZUSER" "$ZPASS")" \
        | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN" ] || { echo "ОШИБКА: не удалось войти в Zabbix API ($ZUSER)"; exit 1; }

GROUPID=$(api group.get "$(printf '{"jsonrpc":"2.0","method":"hostgroup.get","params":{"filter":{"name":"%s"}},"auth":"%s","id":2}' "$GROUP" "$TOKEN")" \
          | grep -o '"groupid":"[0-9]*"' | head -1 | cut -d'"' -f4)
if [ -z "$GROUPID" ]; then
    GROUPID=$(api group.create "$(printf '{"jsonrpc":"2.0","method":"hostgroup.create","params":{"name":"%s"},"auth":"%s","id":3}' "$GROUP" "$TOKEN")" \
              | grep -o '"groupids":\["[0-9]*"\]' | grep -o '[0-9]*')
fi
TPLID=$(api template.get '{"jsonrpc":"2.0","method":"template.get","params":{"filter":{"host":["Linux by Zabbix agent active"]},"output":["templateid"]},"auth":"'$TOKEN'","id":4}' \
        | grep -o '"templateid":"[0-9]*"' | head -1 | cut -d'"' -f4)
[ -n "$TPLID" ] || { echo "ОШИБКА: шаблон 'Linux by Zabbix agent active' не найден"; exit 1; }

EXIST=$(api host.get "$(printf '{"jsonrpc":"2.0","method":"host.get","params":{"filter":{"host":"%s"}},"output":["hostid"],"auth":"%s","id":5}' "$NAME" "$TOKEN")" \
        | grep -o '"hostid":"[0-9]*"' | head -1 | cut -d'"' -f4)

if [ -n "$EXIST" ]; then
    echo "Хост $NAME уже существует (hostid=$EXIST) — обновляю PSK и шаблон"
    api host.update "$(printf '{"jsonrpc":"2.0","method":"host.update","params":{"hostid":"%s","templates":[{"templateid":"%s"}],"tls_connect":2,"tls_accept":2,"tls_psk_identity":"%s","tls_psk":"%s"},"auth":"%s","id":6}' "$EXIST" "$TPLID" "$NAME" "$PSK" "$TOKEN")" > /dev/null
    HOSTID=$EXIST
else
    RES=$(api host.create "$(printf '{"jsonrpc":"2.0","method":"host.create","params":{"host":"%s","interfaces":[{"type":1,"main":1,"useip":1,"ip":"%s","port":"10050","dns":""}],"groups":[{"groupid":"%s"}],"templates":[{"templateid":"%s"}],"tls_connect":2,"tls_accept":2,"tls_psk_identity":"%s","tls_psk":"%s","description":"Клубный сервер (active checks + PSK)"},"auth":"%s","id":7}' "$NAME" "$IP" "$GROUPID" "$TPLID" "$NAME" "$PSK" "$TOKEN")")
    HOSTID=$(echo "$RES" | grep -o '"hostids":\["[0-9]*"\]' | grep -o '[0-9]*')
    [ -n "$HOSTID" ] || { echo "ОШИБКА создания хоста:"; echo "$RES"; exit 1; }
fi

cat <<EOF

=== Хост зарегистрирован в Zabbix ===
hostid:    $HOSTID
hostname:  $NAME
group:     $GROUP ($GROUPID)
template:  Linux by Zabbix agent active ($TPLID)
psk identity: $NAME
psk key:      $PSK

Теперь на клубном сервере ($NAME):
  sudo bash install-agent.sh --active --server 83.237.97.70:10051 --name $NAME --psk $PSK
(или скачайте скрипт из репо: /opt/monitoring/scripts/install-agent.sh)
EOF
