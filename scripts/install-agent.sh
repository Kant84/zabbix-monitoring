#!/bin/bash
# =============================================================================
# install-agent.sh v4.2.2 — zabbix-agent2 (+ node_exporter) на Linux-хост.
# Три режима:
#
# 1) ОФИС/ФИЛИАЛ-VPN (пассивные проверки), локально:
#      sudo ./install-agent.sh --server 192.168.88.36 --name mobile
#
# 2) PUSH с сервера мониторинга на список машин:
#      sudo ./install-agent.sh --push --server 192.168.88.36 --user nfc \
#          --targets "192.168.88.43:mobile 192.168.88.45:mobile1"
#
# 3) КЛУБ через интернет (active checks + PSK) — сервер сам стучится в офис:
#      sudo ./install-agent.sh --active --server 83.237.97.70:10051 \
#          --name club-nn-fizra --psk <64-hex из add-club-host.sh>
#    Хост в Zabbix должен быть создан заранее: scripts/add-club-host.sh (на сервере).
# =============================================================================
set -e

SERVER=""; NAME=""; PUSH=0; SSH_USER="nfc"; TARGETS=""; ACTIVE=0; PSK=""; PASSIVE_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --server)  SERVER="$2";   shift 2;;
        --name)    NAME="$2";     shift 2;;
        --push)    PUSH=1;        shift;;
        --user)    SSH_USER="$2"; shift 2;;
        --targets) TARGETS="$2";  shift 2;;
        --active)  ACTIVE=1;      shift;;
        --passive-only) PASSIVE_ONLY=1; shift;;
        --psk)     PSK="$2";      shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ -n "$SERVER" ] || { echo "Укажите --server <IP[:порт] сервера мониторинга>"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo $0 ..."; exit 1; }
if [ "$ACTIVE" -eq 1 ]; then
    [ -n "$PSK" ] || { echo "В режиме --active обязателен --psk <64 hex> (см. add-club-host.sh)"; exit 1; }
    [ "${#PSK}" -eq 64 ] || { echo "PSK должен быть 64 hex-символа"; exit 1; }
fi
if [ "$PASSIVE_ONLY" -eq 1 ]; then
    [ -n "$PSK" ] || { echo "В режиме --passive-only обязателен --psk (сервер ходит к агенту по интернету — только PSK)"; exit 1; }
fi

install_local() {
    local name="${1:-$(hostname)}"
    . /etc/os-release
    echo "=== ОС: $PRETTY_NAME ==="
    rm -f /tmp/zabbix-release.deb
    if ! wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/${ID}/pool/main/z/zabbix-release/zabbix-release_latest+${ID}${VERSION_ID}_all.deb"; then
        wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
    fi
    dpkg -i /tmp/zabbix-release.deb
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y zabbix-agent2 prometheus-node-exporter

    CONF=/etc/zabbix/zabbix_agent2.conf
    if [ "$PASSIVE_ONLY" -eq 1 ]; then
        # Клуб с публичным IP: офисный сервер сам стучится сюда (passive 10050).
        # Server= = source-IP подключений сервера (после src-nat Mikrotik = белый IP офиса).
        sed -i "s/^Server=.*/Server=${SERVER}/" "$CONF"
        sed -i "s/^ServerActive=.*/ServerActive=127.0.0.1/" "$CONF"
        sed -i "s/^Hostname=.*/Hostname=${name}/" "$CONF"
        printf '%s\n' "$PSK" > /etc/zabbix/zabbix_agentd.psk
        chmod 600 /etc/zabbix/zabbix_agentd.psk
        for opt in "TLSConnect=psk" "TLSAccept=psk" "TLSPSKIdentity=${name}" "TLSPSKFile=/etc/zabbix/zabbix_agentd.psk"; do
            k="${opt%%=*}"
            grep -q "^${k}=" "$CONF" && sed -i "s|^${k}=.*|${opt}|" "$CONF" || echo "$opt" >> "$CONF"
        done
        echo "PSK записан: /etc/zabbix/zabbix_agentd.psk (identity: ${name})"
        echo "Не забудь файрвол: разрешить TCP 10050/9100 ТОЛЬКО с ${SERVER}"
    elif [ "$ACTIVE" -eq 1 ]; then
        # Клубный режим: только активные проверки, PSK-шифрование
        sed -i "s/^Server=.*/Server=127.0.0.1/" "$CONF"
        sed -i "s/^ServerActive=.*/ServerActive=${SERVER}/" "$CONF"
        sed -i "s/^Hostname=.*/Hostname=${name}/" "$CONF"
        printf '%s\n' "$PSK" > /etc/zabbix/zabbix_agentd.psk
        chmod 600 /etc/zabbix/zabbix_agentd.psk
        grep -q "^HostMetadata=" "$CONF" && sed -i "s/^HostMetadata=.*/HostMetadata=Linux club/" "$CONF" || echo "HostMetadata=Linux club" >> "$CONF"
        for opt in "TLSConnect=psk" "TLSAccept=psk" "TLSPSKIdentity=${name}" "TLSPSKFile=/etc/zabbix/zabbix_agentd.psk"; do
            k="${opt%%=*}"
            grep -q "^${k}=" "$CONF" && sed -i "s|^${k}=.*|${opt}|" "$CONF" || echo "$opt" >> "$CONF"
        done
        echo "PSK записан: /etc/zabbix/zabbix_agentd.psk (identity: ${name})"
    else
        sed -i "s/^Server=.*/Server=${SERVER}/; s/^ServerActive=.*/ServerActive=${SERVER}/; s/^Hostname=.*/Hostname=${name}/" "$CONF"
    fi
    systemctl enable --now zabbix-agent2 prometheus-node-exporter
    systemctl restart zabbix-agent2
    echo "=== Агент установлен ==="
    echo "Режим:        $( [ "$PASSIVE_ONLY" -eq 1 ] && echo 'PASSIVE-ONLY публичный IP (клуб, PSK)' || ([ "$ACTIVE" -eq 1 ] && echo 'ACTIVE (клуб, PSK)' || echo 'passive/active') )"
    echo "Zabbix Server: ${SERVER}"
    echo "Hostname:      ${name}"
    echo "Порты:         10050 (agent), 9100 (node_exporter)"
    if [ "$ACTIVE" -eq 1 ]; then
        echo "Дальше: Data collection → Hosts → $name → должен стать Available (agent active) за 1-2 минуты."
    else
        echo "Сервер найдёт этот хост автоматически (сканер офиса, до 10 мин)."
    fi
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
