#!/bin/bash
# =============================================================================
# install-security.sh v1.0 — НАБЛЮДЕНИЕ за SSH (без банов, только алерты):
#   textfile-коллектор node_exporter: каждую минуту парсит /var/log/auth.log,
#   метрики ssh_failed_logins_total{ip,user} / ssh_success_logins_total{ip,user}
#   едут по УЖЕ открытому порту 9100 (клубам роутер не трогаем).
#   sudo ./install-security.sh
#   sudo ./install-security.sh --push --user nfc --targets "ip:name ..."
# Алерты: SshBruteForce (подбор с ЧУЖИХ ip), SshLoginSuccess (любой вход),
#         SshRootLogin (вход root). VPN 10.10.1.x и локалки 192.168.x.x — «свои».
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
    TF=/var/lib/node_exporter/textfile_metrics
    mkdir -p "$TF"

    # 1. Включаем textfile-коллектор в node_exporter
    DEF=/etc/default/prometheus-node-exporter
    if [ -f "$DEF" ] && grep -q "textfile.directory" "$DEF"; then
        echo "textfile-коллектор уже включён"
    else
        if [ -f "$DEF" ]; then
            sed -i 's|^ARGS="\(.*\)"|ARGS="\1 --collector.textfile.directory='${TF}'"|' "$DEF" 2>/dev/null || true
            grep -q "textfile.directory" "$DEF" || echo "ARGS="--collector.textfile.directory=${TF}"" >> "$DEF"
        else
            echo "ARGS="--collector.textfile.directory=${TF}"" > "$DEF"
        fi
        systemctl restart prometheus-node-exporter
    fi

    # 2. Парсер auth.log -> textfile (кумулятивные счётчики, state-файл)
    cat > /usr/local/bin/auth-metrics.sh <<'SCRIPT'
#!/bin/bash
# auth-metrics.sh: кумулятивные счётчики SSH-событий для node_exporter textfile
TF=/var/lib/node_exporter/textfile_metrics
STATE=/var/lib/node_exporter/.auth_totals
LOG=/var/log/auth.log
mkdir -p "$TF"
[ -f "$LOG" ] || exit 0
TOTAL=$(wc -l < "$LOG")
LAST=$(cat /var/lib/node_exporter/.auth_last 2>/dev/null || echo 0)
[ "$LAST" -gt "$TOTAL" ] && LAST=0   # ротация лога
[ "$LAST" -eq "$TOTAL" ] && exit 0

sed -n "$((LAST+1)),${TOTAL}p" "$LOG" | awk -v STATE="$STATE" -v STNEW="${STATE}.new" -v OUT="${TF}/auth.prom" '
  FNR==NR { if ($0 ~ /\|/) { split($0,a,"|"); if (a[3] != "") F[a[1]"|"a[2]]=a[3]; if (a[4] != "") O[a[1]"|"a[2]]=a[4] } next }
  /Failed password/ { ip=$NF; user=""; for(i=1;i<=NF;i++) if($i=="for"){user=$(i+1);break}; F[ip"|"user]++ }
  /Accepted (password|publickey)/ { ip=$NF; user=""; for(i=1;i<=NF;i++) if($i=="for"){user=$(i+1);break}; O[ip"|"user]++ }
  END {
    printf "# HELP ssh_failed_logins_total Неудачные SSH-попытки\n# TYPE ssh_failed_logins_total counter\n" > OUT
    for (k in F) { split(k,a,"|"); printf "ssh_failed_logins_total{ip=\"%s\",user=\"%s\"} %d\n", a[1], a[2], F[k] >> OUT }
    printf "# HELP ssh_success_logins_total Успешные SSH-входы\n# TYPE ssh_success_logins_total counter\n" >> OUT
    for (k in O) { split(k,a,"|"); printf "ssh_success_logins_total{ip=\"%s\",user=\"%s\"} %d\n", a[1], a[2], O[k] >> OUT }
    for (k in F) printf "%s|%d|%d\n", k, F[k], O[k]+0 > STNEW
    close(STNEW)
  }' "$STATE" - && mv "${STATE}.new" "$STATE" 2>/dev/null || true
echo "$TOTAL" > /var/lib/node_exporter/.auth_last
SCRIPT
    chmod +x /usr/local/bin/auth-metrics.sh
    touch /var/lib/node_exporter/.auth_totals

    # 3. Таймер раз в минуту
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
    sleep 65
    /usr/local/bin/auth-metrics.sh || true
    echo "метрик ssh_: $(grep -c '^ssh_' "${TF}/auth.prom" 2>/dev/null || echo 0)"
    echo "=== SSH-НАБЛЮДЕНИЕ УСТАНОВЛЕНО (без банов) ==="
}

if [ "$PUSH" -eq 1 ]; then
    [ -n "$TARGETS" ] || { echo "В --push нужен --targets 'ip:name ...'"; exit 1; }
    for t in $TARGETS; do
        ip="${t%%:*}"; echo "=== $ip ==="
        scp "$0" "${SSH_USER}@${ip}:/tmp/install-security.sh"
        ssh "${SSH_USER}@${ip}" "sudo bash /tmp/install-security.sh"
    done
    echo "=== PUSH ЗАВЕРШЁН ==="
else
    install_local
fi
