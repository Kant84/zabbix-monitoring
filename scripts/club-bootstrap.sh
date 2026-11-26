#!/bin/bash
# =============================================================================
# club-bootstrap.sh v1.0 — ПОЛНЫЙ набор мониторинга на сервере НОВОГО КЛУБА.
# Один запуск ставит всё: zabbix-agent2+node_exporter (passive, PSK),
# smartctl_exporter (SMART), SSH-наблюдение, СКУД-пробник (itcservice+терминалы).
#
# ПЕРЕД ЗАПУСКОМ (на сервере мониторинга, monitor):
#   1) sudo ./scripts/add-club-host.sh --name club-<city>-<short> --ip <публ.IP>
#      → скопируй из вывода PSK (psk key)
#   2) На роутере клуба должны быть пробросы: 9100, 10050, 9633 (внешние любые,
#      внутренние = те же номера на внутренний IP сервера), SSH (22) — для тебя.
#
# ЗАПУСК (на сервере клуба, под root):
#   sudo bash club-bootstrap.sh --server 83.237.97.70 --name club-<city>-<short> --psk <64hex>
#
# ПОСЛЕ: заполни /etc/zabbix-monitor/skud.conf (адреса терминалов клуба) —
#   шаблон уже лежит на месте, правь строки под клуб.
# =============================================================================
set -e
BASE="https://raw.githubusercontent.com/Kant84/zabbix-monitoring/main/scripts"
SERVER=""; NAME=""; PSK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2;;
        --name)   NAME="$2";   shift 2;;
        --psk)    PSK="$2";    shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ -n "$SERVER" ] && [ -n "$NAME" ] && [ -n "$PSK" ] || { echo "Нужны --server, --name, --psk (см. add-club-host.sh на сервере мониторинга)"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo bash $0 ..."; exit 1; }

step(){ echo ""; echo "############ $1 ############"; }

step "1/5 Zabbix-агент + node_exporter (passive-only, PSK)"
wget -q "$BASE/install-agent.sh" -O /tmp/install-agent.sh
bash /tmp/install-agent.sh --passive-only --server "$SERVER" --name "$NAME" --psk "$PSK"

step "2/5 SMART дисков (smartctl_exporter :9633)"
wget -q "$BASE/install-addon.sh" -O /tmp/install-addon.sh
bash /tmp/install-addon.sh --smart --systemd

step "3/5 Наблюдение за SSH (входы/подбор/root, без банов)"
wget -q "$BASE/install-security.sh" -O /tmp/install-security.sh
wget -q "$BASE/auth-metrics.py" -O /tmp/auth-metrics.py   # парсер, который ищет install-security.sh рядом с собой
bash /tmp/install-security.sh

step "4/5 СКУД-пробник (itcservice + терминалы по HTTP)"
wget -q "$BASE/skud-probe.py" -O /usr/local/bin/skud-probe.py
chmod 755 /usr/local/bin/skud-probe.py
mkdir -p /etc/zabbix-monitor
[ -f /etc/zabbix-monitor/skud.conf ] || cat > /etc/zabbix-monitor/skud.conf <<EOF
# Проверки СКУД: по строке на устройство.
#   service:<имя службы>           — контроль systemd-службы
#   http://<IP>:<порт><путь>|<Название>   — HTTP-проверка (код < 500 = живо)
# Пример (замени IP/названия под этот клуб):
service:itcservice
http://127.0.0.1:8585|Веб СКУД (itcservice)
#http://192.168.50.28:9000/login|Вход левый (ITC X1)
#http://192.168.50.34:9000/login|Вход правый (ITC X1)
#http://192.168.50.32:9000/setup|Выход левый (Firefly)
#http://192.168.50.85:9000/setup|Выход правый (Firefly)
EOF
for u in skud-probe.service skud-probe.timer; do
    wget -q "https://raw.githubusercontent.com/Kant84/zabbix-monitoring/main/systemd/$u" -O /etc/systemd/system/$u
done
systemctl daemon-reload
systemctl enable --now skud-probe.timer
/usr/local/bin/skud-probe.py || true

step "5/5 Итог"
echo "Агент:        Hostname=$NAME, Server=$SERVER (PSK ок)"
echo "SMART:        :9633 (см. ниже активность)"
echo "SSH-метрики:  textfile -> :9100"
echo "СКУД:         /etc/zabbix-monitor/skud.conf — ОТРЕДАКТИРУЙ под клуб (раскомментируй терминалы)"
echo ""
echo "Проверки на сервере мониторинга (через 5-10 мин):"
echo "  Zabbix: хост $NAME -> Available"
echo "  Grafana: All Servers -> карточка клуба, SSD-панели, «СКУД: устройства»"
echo "  curl-проверки: nc -z -w3 <публ.IP> 9100 / 10050 / 9633"
