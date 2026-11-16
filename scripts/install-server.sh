#!/bin/bash
# Установка центрального сервера мониторинга:
# Zabbix Server + MySQL + Prometheus + Alertmanager + Grafana + Webhook + сканеры
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# === Параметры (переопределяются env) ===
DB_PASSWORD="${DB_PASSWORD:-zabbix_password_change_me}"
ZABBIX_VERSION="${ZABBIX_VERSION:-7.0}"   # проверьте актуальную на https://repo.zabbix.com
INSTALL_DIR="${INSTALL_DIR:-/opt/monitoring}"

if [ "$EUID" -ne 0 ]; then echo "Запустите от root"; exit 1; fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}Клонируйте репозиторий: git clone <repo> $INSTALL_DIR${NC}"; exit 1
fi

# === Автоопределение ОС (Ubuntu/Debian, любая поддерживаемая версия) ===
. /etc/os-release
OS_ID="$ID"            # ubuntu | debian
OS_CODENAME="$VERSION_CODENAME"   # jammy | noble | bullseye | bookworm | trixie
OS_MAJOR="$(echo "$VERSION_ID" | cut -d. -f1)"

echo -e "${GREEN}=== ОС: $PRETTY_NAME (версия $OS_MAJOR, codename $OS_CODENAME) ===${NC}"

# Для Debian Zabbix-коденеймы отличаются: Debian 11→bullseye, 12→bookworm, 13→trixie
ZBX_CODENAME="$OS_CODENAME"
echo -e "${YELLOW}=== Проверка доступности репозитория Zabbix $ZABBIX_VERSION/$ZBX_CODENAME ===${NC}"

# === 1. Репозиторий Zabbix ===
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/${OS_ID}/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+${ZBX_CODENAME}_all.deb" -O /tmp/zabbix-release.deb || {
    echo -e "${YELLOW}Репозиторий для ${OS_ID}/${ZBX_CODENAME} не найден — пробуем ubuntu/noble как универсальный...${NC}"
    wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+noble_all.deb" -O /tmp/zabbix-release.deb
}
dpkg -i /tmp/zabbix-release.deb
apt update

# === 2. Пакеты ===
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent2 mysql-server

# === 3. MySQL ===
systemctl start mysql && systemctl enable mysql
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
SQL

zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p"${DB_PASSWORD}" zabbix
mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# === 4. Конфиг Zabbix Server ===
sed "s/DBPassword=.*/DBPassword=${DB_PASSWORD}/" "$INSTALL_DIR/configs/zabbix/zabbix_server.conf" > /etc/zabbix/zabbix_server.conf

systemctl restart zabbix-server zabbix-agent2 apache2
systemctl enable zabbix-server zabbix-agent2 apache2
echo -e "${GREEN}=== Zabbix Server установлен: http://$(hostname -I | awk '{print $1}')/zabbix ===${NC}"

# === 5. Prometheus + Node Exporter ===
echo -e "${GREEN}=== Установка Prometheus ===${NC}"
apt install -y prometheus prometheus-node-exporter
mkdir -p /etc/prometheus/file-sd/branches /etc/prometheus/file-sd/office
cp "$INSTALL_DIR/configs/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
cp "$INSTALL_DIR/configs/prometheus/alerts.yml" /etc/prometheus/alerts.yml
cp "$INSTALL_DIR/configs/prometheus/file-sd/branches/"*.json /etc/prometheus/file-sd/branches/
cp "$INSTALL_DIR/configs/prometheus/file-sd/office/"*.json /etc/prometheus/file-sd/office/
chown -R prometheus:prometheus /etc/prometheus/file-sd
systemctl restart prometheus prometheus-node-exporter
systemctl enable prometheus prometheus-node-exporter

# === 6. Alertmanager ===
apt install -y prometheus-alertmanager
cp "$INSTALL_DIR/configs/alertmanager/alertmanager.yml" /etc/prometheus/alertmanager.yml
mkdir -p /etc/prometheus/alertmanager-templates
cp "$INSTALL_DIR/configs/alertmanager/templates/default.tmpl" /etc/prometheus/alertmanager-templates/
systemctl restart prometheus-alertmanager
systemctl enable prometheus-alertmanager

# === 7. Grafana ===
echo -e "${GREEN}=== Установка Grafana ===${NC}"
apt install -y apt-transport-https software-properties-common
if [ ! -f /usr/share/keyrings/grafana.key ]; then
    wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
    echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
    apt update
fi
apt install -y grafana
systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server
grafana cli plugins install alexanderzobnin-zabbix-app || true
systemctl restart grafana-server

# Provisioning: datasource + dashboards
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /etc/grafana/dashboards
cp "$INSTALL_DIR/configs/grafana/provisioning/datasources/datasources.yml" /etc/grafana/provisioning/datasources/
cp "$INSTALL_DIR/configs/grafana/provisioning/dashboards/dashboards.yml" /etc/grafana/provisioning/dashboards/
cp "$INSTALL_DIR/configs/grafana/dashboards/all-servers.json" /etc/grafana/dashboards/
systemctl restart grafana-server

# === 8. Webhook-сервер (MAX) ===
echo -e "${GREEN}=== Установка MAX Webhook Server ===${NC}"
apt install -y python3-pip python3-flask python3-requests

cat > /etc/default/max-webhook-server <<'EOF'
# ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ:
MAX_BOT_TOKEN=YOUR_BOT_TOKEN_HERE
MAX_API_URL=https://platform-api.max.ru/messages
MAX_CHAT_ID=YOUR_CHAT_ID
WEBHOOK_PORT=5000
LOG_FILE=/var/log/max-webhook-server.log
EOF
chmod 600 /etc/default/max-webhook-server

cp "$INSTALL_DIR/webhook/max-webhook-server.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable max-webhook-server
systemctl start max-webhook-server

# === 9. Конфиги сканеров + systemd таймеры ===
mkdir -p /etc/zabbix-monitor
cat > /etc/zabbix-monitor/branches.conf <<'EOF'
# Формат: <city> <подсеть-без-последнего-октета> <region>
# ЗАМЕНИТЕ на реальные подсети ваших филиалов!
msk 10.200.1 moscow
spb 10.200.2 northwest
kzn 10.200.3 volga
nsk 10.200.4 siberia
EOF
echo 'OFFICE_SUBNET=10.100.0' > /etc/zabbix-monitor/office.conf

cp "$INSTALL_DIR/systemd/"scanner-*.service "$INSTALL_DIR/systemd/"scanner-*.timer /etc/systemd/system/
chmod +x "$INSTALL_DIR/scripts/"*.sh
systemctl daemon-reload
systemctl enable --now scanner-branches.timer
systemctl enable --now scanner-office.timer

echo ""
echo -e "${GREEN}=== ВСЁ УСТАНОВЛЕНО ===${NC}"
echo "Zabbix:       http://$(hostname -I | awk '{print $1}')/zabbix"
echo "Grafana:      http://$(hostname -I | awk '{print $1}'):3000"
echo "Prometheus:   http://$(hostname -I | awk '{print $1}'):9090"
echo "Alertmanager: http://$(hostname -I | awk '{print $1}'):9093"
echo ""
echo "Дальше: nano /etc/default/max-webhook-server, затем ./scripts/test-all.sh"
