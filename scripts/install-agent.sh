#!/bin/bash
# =============================================================================
# install-agent.sh v4.2 — zabbix-agent2 + node_exporter на Linux-хост.
# ДВУСТОРОННИЙ, два режима:
#
# 1) ЛОКАЛЬНО (на машине-агенте):
#      sudo ./install-agent.sh --server 192.168.88.36 --name mobile
#
# 2) PUSH С СЕРВЕРА МОНИТОРИНГА (одна команда на все машины сети):
#      sudo ./install-agent.sh --push --server 192.168.88.36 --user nfc \
#          --targets "192.168.88.43:mobile 192.168.88.45:mobile1 192.168.88.35:nfc35"
#    Требование: SSH-доступ ${user}@ip с правом sudo.
#
# После установки хост появится в Grafana автоматически (сканер офиса, ≤10 мин).
# =============================================================================
set -e

SERVER=""; NAME=""; PUSH=0; SSH_USER="nfc"; TARGETS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --server)  SERVER="$2";   shift 2;;
        --name)    NAME="$2";     shift 2;;
        --push)    PUSH=1;        shift;;
        --user)    SSH_USER="$2"; shift 2;;
        --targets) TARGETS="$2";  shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ -n "$SERVER" ] || { echo "Укажите --server <IP сервера мониторинга>"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo $0 ..."; exit 1; }

install_local() {
    local name="${1:-$(hostname)}"
    . /etc/os-release
    echo "=== ОС: $PRETTY_NAME ==="
    # Репозиторий Zabbix: имя пакета +ubuntu22.04 (ID+VERSION_ID, НЕ +jammy),
    # путь БЕЗ /release/. Старый битый /tmp/zabbix-release.deb удаляем заранее.
    rm -f /tmp/zabbix-release.deb
    if ! wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/${ID}/pool/main/z/zabbix-release/zabbix-release_latest+${ID}${VERSION_ID}_all.deb"; then
        wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
    fi
    dpkg -i /tmp/zabbix-release.deb
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y zabbix-agent2 prometheus-node-exporter
    sed -i "s/^Server=.*/Server=${SERVER}/; s/^ServerActive=.*/ServerActive=${SERVER}/; s/^Hostname=.*/Hostname=${name}/" /etc/zabbix/zabbix_agent2.conf
    systemctl enable --now zabbix-agent2 prometheus-node-exporter
    systemctl restart zabbix-agent2
    echo "=== Агент установлен ==="
    echo "Zabbix Server: ${SERVER}"
    echo "Hostname:      ${name}"
    echo "Порты:         10050 (agent), 9100 (node_exporter)"
    echo "Сервер найдёт этот хост автоматически (сканер офиса, до 10 мин)."
}

if [ "$PUSH" -eq 1 ]; then
    [ -n "$TARGETS" ] || { echo "В режиме --push нужен --targets 'ip:name ip:name'"; exit 1; }
    for t in $TARGETS; do
        ip="${t%%:*}"; name="${t##*:}"
        echo "=== $ip ($name) ==="
        scp "$0" "${SSH_USER}@${ip}:/tmp/install-agent.sh"
        ssh "${SSH_USER}@${ip}" "sudo bash /tmp/install-agent.sh --server ${SERVER} --name ${name}"
    done
    echo "=== PUSH завершён: все цели обработаны ==="
else
    install_local "$NAME"
fi
