#!/bin/bash
# =============================================================================
# install-addon.sh v1.0 — доп. мониторинг харда и служб (самоопределение):
#   --systemd  коллектор systemd в node_exporter (состояние ВСЕХ служб:
#              упала любая (1С, СКУД, nginx, postgresql...) — алерт с именем)
#   --smart    smartctl_exporter (SMART дисков: health, температура, износ)
#              + smartmontools. Порт 9633. Диски определяет сам smartctl.
#   --push --user nfc --targets "ip:name ..."  — установка на список машин.
#
#   sudo ./install-addon.sh --smart --systemd
# =============================================================================
set -e
SMART=0; SYSTEMD=0; PUSH=0; SSH_USER="nfc"; TARGETS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --smart)    SMART=1;      shift;;
        --systemd)  SYSTEMD=1;    shift;;
        --push)     PUSH=1;       shift;;
        --user)     SSH_USER="$2"; shift 2;;
        --targets)  TARGETS="$2";  shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo $0 ..."; exit 1; }
[ "$SMART" -eq 0 ] && [ "$SYSTEMD" -eq 0 ] && { echo "Укажите --smart и/или --systemd"; exit 1; }

install_local() {
    echo "=== ОС: $(. /etc/os-release; echo $PRETTY_NAME) ==="

    if [ "$SYSTEMD" -eq 1 ]; then
        echo "--- systemd collector (node_exporter) ---"
        DEF=/etc/default/prometheus-node-exporter
        if [ -f "$DEF" ] && grep -q "collector.systemd" "$DEF"; then
            echo "уже включён"
        else
            mkdir -p "$(dirname "$DEF")"
            if [ -f "$DEF" ]; then
                sed -i 's|^ARGS="\(.*\)"|ARGS="\1 --collector.systemd"|' "$DEF" 2>/dev/null || echo 'ARGS="--collector.systemd"' >> "$DEF"
                grep -q "collector.systemd" "$DEF" || echo 'ARGS="--collector.systemd"' >> "$DEF"
            else
                echo 'ARGS="--collector.systemd"' > "$DEF"
            fi
            systemctl restart prometheus-node-exporter
        fi
        sleep 2
        curl -s localhost:9100/metrics | grep -q "node_systemd_units" \
            && echo "OK: node_systemd_units отдаётся" \
            || echo "ВНИМАНИЕ: node_systemd_units не найден — проверьте лог node_exporter"
    fi

    if [ "$SMART" -eq 1 ]; then
        echo "--- smartctl_exporter (SMART дисков) ---"
        DEBIAN_FRONTEND=noninteractive apt install -y smartmontools curl
        TAG=$(curl -s https://api.github.com/repos/prometheus-community/smartctl_exporter/releases/latest \
              | grep '"tag_name"' | cut -d'"' -f4)
        [ -n "$TAG" ] || { echo "ОШИБКА: не узнал версию smartctl_exporter"; exit 1; }
        echo "Версия: $TAG"
        cd /tmp
        rm -rf smartctl_exporter-*.linux-amd64*
        wget -q "https://github.com/prometheus-community/smartctl_exporter/releases/download/${TAG}/smartctl_exporter-${TAG#v}.linux-amd64.tar.gz"
        tar xzf "smartctl_exporter-${TAG#v}.linux-amd64.tar.gz"
        install -m 755 "smartctl_exporter-${TAG#v}.linux-amd64/smartctl_exporter" /usr/local/bin/smartctl_exporter
        cat > /etc/systemd/system/smartctl-exporter.service <<EOF
[Unit]
Description=smartctl exporter (SMART disks)
After=network.target

[Service]
ExecStart=/usr/local/bin/smartctl_exporter --smartctl.device-exclude="nvme[1-9]" \
    --web.listen-address=0.0.0.0:9633
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now smartctl-exporter
        sleep 3
        systemctl is-active smartctl-exporter
        ss -tlnp | grep 9633
        echo "OK: smartctl_exporter слушает :9633"
    fi
    echo "=== ADDON УСТАНОВЛЕН ==="
}

if [ "$PUSH" -eq 1 ]; then
    [ -n "$TARGETS" ] || { echo "В --push нужен --targets 'ip:name ip:name'"; exit 1; }
    for t in $TARGETS; do
        ip="${t%%:*}"; name="${t##*:}"
        echo "=== $ip ($name) ==="
        scp "$0" "${SSH_USER}@${ip}:/tmp/install-addon.sh"
        ssh "${SSH_USER}@${ip}" "sudo bash /tmp/install-addon.sh --smart --systemd"
    done
    echo "=== PUSH ЗАВЕРШЁН ==="
else
    install_local
fi
