#!/bin/bash
# =============================================================================
# connect-club.sh v1.0 — подключение клуба «под ключ» с СЕРВЕРА МОНИТОРИНГА
# (выполняется на monitor, 192.168.88.36). Делает сторону Zabbix/Prometheus
# и печатает точные команды для сервера клуба + список пробросов на роутере.
#
#   sudo ./connect-club.sh --name club-nn-fizra --ip 5.227.70.150
#
# Порты, которые нужно пробросить на РОУТЕРЕ КЛУБА (внешний = внутренний!):
#   9100  -> <внутр.IP>:9100    node_exporter (метрики в Grafana)
#   10050 -> <внутр.IP>:10050   zabbix-agent2 (опрос Zabbix, PSK)
#   9633  -> <внутр.IP>:9633    smartctl_exporter (SMART дисков)
# + резервирование DHCP сервера на роутере.
# =============================================================================
set -e
NAME=""; IP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2;;
        --ip)   IP="$2";   shift 2;;
        *) echo "Неизвестный аргумент: $1"; exit 1;;
    esac
done
[ -n "$NAME" ] && [ -n "$IP" ] || { echo "Нужны --name club-<city> --ip <публичный IP>"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "От root: sudo $0 ..."; exit 1; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1/3 Регистрация хоста в Zabbix (API) ==="
"$ROOT_DIR/scripts/add-club-host.sh" --name "$NAME" --ip "$IP" | tee /tmp/club_reg.txt
PSK=$(grep "psk key:" /tmp/club_reg.txt | awk '{print $3}')

echo "=== 2/3 Сканер SMART: добавляю клуб ==="
CONF=/etc/zabbix-monitor/smart.conf
touch "$CONF"
grep -qx "$IP" "$CONF" || echo "$IP" >> "$CONF"
echo "$IP -> $CONF (сканер подхватит за ≤10 мин)"

echo "=== 3/3 Команды для СЕРВЕРА КЛУБА ($IP) ==="
cat <<EOF

# --- выполни на клубе (по SSH, под своим пользователем с sudo) ---
wget -q https://raw.githubusercontent.com/Kant84/zabbix-monitoring/main/scripts/install-agent.sh
sudo bash install-agent.sh --passive-only --server 83.237.97.70 --name $NAME --psk $PSK
wget -q https://raw.githubusercontent.com/Kant84/zabbix-monitoring/main/scripts/install-addon.sh
sudo bash install-addon.sh --smart --systemd
# файрвол (свой SSH-порт подставь первым):
sudo iptables -I INPUT 1 -p tcp --dport <SSH-порт> -j ACCEPT
sudo iptables -I INPUT 2 -p tcp -s 83.237.97.70 --dport 10050 -j ACCEPT
sudo iptables -I INPUT 3 -p tcp -s 83.237.97.70 --dport 9100 -j ACCEPT
sudo iptables -I INPUT 4 -p tcp -s 83.237.97.70 --dport 9633 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 10050 -j DROP
sudo iptables -A INPUT -p tcp --dport 9100 -j DROP
sudo iptables -A INPUT -p tcp --dport 9633 -j DROP
sudo mkdir -p /etc/iptables && sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

=== Готово со стороны мониторинга ===
Проверки (через 5-10 мин):
  Zabbix: хост $NAME -> Available
  Grafana: All Servers -> плашка $IP, SSD-панели, systemd
  curl с monitor: nc -z -w3 $IP 9100 / 10050 / 9633 -> OPEN
EOF
