#!/bin/bash
# =============================================================================
# install-security.sh v1.1 — НАБЛЮДЕНИЕ за SSH (без банов, только алерты).
# Ставит: парсер scripts/auth-metrics.py (journald или auth.log), textfile
# в /var/lib/prometheus/node-exporter, РОВНО ОДНУ строку ARGS у node_exporter,
# таймер auth-metrics.timer (раз в минуту). Метрики идут по порту 9100 —
# клубам роутер трогать НЕ нужно.
#   sudo ./install-security.sh
#   sudo ./install-security.sh --push --user nfc --targets "ip:name ..."
# Алерты: SshBruteForce (подбор с ЧУЖИХ ip), SshLoginSuccess (вход с IP),
#         SshRootLogin. VPN 10.10.1.x и локалки 192.168.x.x — «свои».
# =============================================================================
set -e
PUSH=0; SSH_USER="nfc"; TARGETS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --push)    PUSH=1;       shift;;
        --user)    SSH_USER="$2"; shift 2;;
        --targets) TARGETS="$2";  shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo $0 ..."; exit 1; }

install_local() {
    echo "=== SSH-наблюдение: $(hostname) ==="
    TF=/var/lib/prometheus/node-exporter
    mkdir -p "$TF"

    # РОВНО ОДНА строка ARGS: стираем все старые, пишем одну чистую
    DEF=/etc/default/prometheus-node-exporter
    touch "$DEF"
    sed -i '/^ARGS=/d' "$DEF"
    echo "ARGS=\"--collector.textfile.directory=${TF}\"" >> "$DEF"
    systemctl restart prometheus-node-exporter

    # Парсер v2 (Python): рядом с этим скриптом или из репо
    SRC="$(cd "$(dirname "$0")" && pwd)/auth-metrics.py"
    [ -f "$SRC" ] || SRC=/opt/monitoring/scripts/auth-metrics.py
    install -m 755 "$SRC" /usr/local/bin/auth-metrics.sh

    cat > /etc/systemd/system/auth-metrics.service <<EOF
[Unit]
Description=SSH auth metrics (textfile)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/auth-metrics.sh
EOF
    cat > /etc/systemd/system/auth-metrics.timer <<EOF
[Unit]
Description=SSH auth metrics every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=60s
Unit=auth-metrics.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now auth-metrics.timer
    sleep 2
    /usr/local/bin/auth-metrics.sh || true
    echo "ssh_ метрик: $(curl -s localhost:9100/metrics | grep -c '^ssh_')"
    echo "=== SSH-НАБЛЮДЕНИЕ УСТАНОВЛЕНО (без банов) ==="
}

if [ "$PUSH" -eq 1 ]; then
    [ -n "$TARGETS" ] || { echo "В --push нужен --targets 'ip:name ...'"; exit 1; }
    for t in $TARGETS; do
        ip="${t%%:*}"; echo "=== $ip ==="
        scp "$0" "$(dirname "$0")/auth-metrics.py" "${SSH_USER}@${ip}:/tmp/"
        ssh "${SSH_USER}@${ip}" "sudo bash /tmp/install-security.sh"
    done
    echo "=== PUSH ЗАВЕРШЁН ==="
else
    install_local
fi
