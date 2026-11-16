#!/bin/bash
# Установка Zabbix Agent2 + Node Exporter на Linux (Ubuntu 22.04-24.04 / Debian 11-13)
# Использование: ./install-agent.sh <IP_сервера_Zabbix> [Hostname]
set -e

ZABBIX_SERVER="${1:?Укажите IP центрального сервера: $0 <zabbix_server_ip> [hostname]}"
HOSTNAME_OVERRIDE="${2:-$(hostname)}"
ZABBIX_VERSION="${ZABBIX_VERSION:-7.0}"

if [ "$EUID" -ne 0 ]; then echo "Запустите от root"; exit 1; fi

# Автоопределение ОС/версии
. /etc/os-release
ZBX_CODENAME="$VERSION_CODENAME"
[ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ] || { echo "Поддерживаются только Ubuntu/Debian"; exit 1; }

echo "=== ОС: $PRETTY_NAME ==="

# Репозиторий Zabbix
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/${ID}/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+${ZBX_CODENAME}_all.deb" -O /tmp/zabbix-release.deb || {
    wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+noble_all.deb" -O /tmp/zabbix-release.deb
}
dpkg -i /tmp/zabbix-release.deb
apt update
apt install -y zabbix-agent2

# Конфиг: гибридный режим (пассивный 10050 + активный)
sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^Hostname=.*/Hostname=${HOSTNAME_OVERRIDE}/" /etc/zabbix/zabbix_agent2.conf
sed -i 's/^# *ListenIP=.*/ListenIP=0.0.0.0/' /etc/zabbix/zabbix_agent2.conf

systemctl restart zabbix-agent2
systemctl enable zabbix-agent2

# Node Exporter
apt install -y prometheus-node-exporter
systemctl restart prometheus-node-exporter
systemctl enable prometheus-node-exporter

# Firewall (если ufw активен)
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 10050/tcp
    ufw allow 9100/tcp
fi

echo ""
echo "=== Агент установлен ==="
echo "Zabbix Server: $ZABBIX_SERVER"
echo "Hostname:      $HOSTNAME_OVERRIDE"
echo "Порты:         10050 (agent), 9100 (node_exporter)"
echo "Сервер найдёт этот хост автоматически (сканер, до 10-30 мин)."
