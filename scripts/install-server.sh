#!/bin/bash
# =============================================================================
# install-server.sh v4.2 — сервер стека мониторинга (Zabbix+MySQL+Prometheus+
# Alertmanager+Grafana+MAX-webhook+сканеры). Battle-tested Ubuntu 22.04/24.04.
#
#   sudo ./install-server.sh                      # офис 192.168.88 по умолчанию
#   sudo OFFICE_SUBNET=10.50.0 ./install-server.sh
#   sudo DB_PASSWORD='секрет' ./install-server.sh
#
# Повторный запуск безопасен (схема БД и конфиги не дублируются).
# =============================================================================
set -e
cd "$(dirname "$0")/.."; ROOT=$(pwd)
[ -f "$ROOT/scripts/install-server.sh" ] || { echo "Запускайте из каталога репозитория"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Запустите от root: sudo $0"; exit 1; }

OFFICE_SUBNET="${OFFICE_SUBNET:-192.168.88}"
DB_PASSWORD="${DB_PASSWORD:-zabbix_password_change_me}"
ZABBIX_VERSION="7.0"
GRAFANA_VERSION="11.1.0"

. /etc/os-release
echo "=== ОС: $PRETTY_NAME ==="

# --- 1. Репозиторий Zabbix -------------------------------------------------
# БАГ v4.1: имя пакета zabbix-release_latest+ubuntu22.04_all.deb (ID+VERSION_ID,
# НЕ +jammy), путь БЕЗ /release/ (этот сегмент — у ветки 8.0).
echo "=== 1. Репозиторий Zabbix $ZABBIX_VERSION ==="
rm -f /tmp/zabbix-release.deb
REL_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${ID}/pool/main/z/zabbix-release/zabbix-release_latest+${ID}${VERSION_ID}_all.deb"
if ! wget -O /tmp/zabbix-release.deb "$REL_URL"; then
    echo "Пробуем запасной вариант (ubuntu24.04)..."
    wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
fi
[ -s /tmp/zabbix-release.deb ] || { echo "ОШИБКА: zabbix-release не скачался"; exit 1; }
dpkg -i /tmp/zabbix-release.deb
apt update

# --- 2. Пакеты --------------------------------------------------------------
echo "=== 2. Пакеты (5-10 минут) ==="
DEBIAN_FRONTEND=noninteractive apt install -y \
    mysql-server zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent2 \
    prometheus prometheus-node-exporter prometheus-alertmanager \
    python3-flask python3-pip python3-requests

# --- 3. MySQL: БД, пользователь, схема --------------------------------------
# БАГ v4.1: путь схемы /usr/share/zabbix-sql-scripts/... (искать через dpkg!),
# импорт под пользователем zabbix → ERROR 1419 (binlog) — поэтому доверяем
# функциям и импортируем от root (auth_socket).
echo "=== 3. MySQL: БД и схема Zabbix ==="
mysql -e "CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"
mysql -e "SET GLOBAL log_bin_trust_function_creators = 1;"
SQL_GZ=$(dpkg -L zabbix-sql-scripts | grep -m1 'mysql/server\.sql\.gz')
[ -n "$SQL_GZ" ] || { echo "ОШИБКА: server.sql.gz не найден"; exit 1; }
TABLES=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix'" 2>/dev/null || echo 0)
if [ "${TABLES:-0}" -lt 50 ]; then
    echo "Импорт схемы из $SQL_GZ (1-2 минуты, молчит — это нормально)..."
    zcat "$SQL_GZ" | mysql --default-character-set=utf8mb4 zabbix
    echo "Схема импортирована."
else
    echo "Схема уже существует ($TABLES таблиц) — пропускаем."
fi
mysql -e "SET GLOBAL log_bin_trust_function_creators = 0;"

sed -i "s/^DBPassword=.*/DBPassword=${DB_PASSWORD}/" /etc/zabbix/zabbix_server.conf
grep -q "^DBPassword=${DB_PASSWORD}" /etc/zabbix/zabbix_server.conf || echo "DBPassword=${DB_PASSWORD}" >> /etc/zabbix/zabbix_server.conf

# --- 4. Prometheus + Alertmanager -------------------------------------------
echo "=== 4. Prometheus и Alertmanager ==="
mkdir -p /etc/prometheus/file-sd/branches /etc/prometheus/file-sd/office
cp "$ROOT/configs/prometheus/prometheus.yml"     /etc/prometheus/prometheus.yml
cp "$ROOT/configs/prometheus/alerts.yml"         /etc/prometheus/alerts.yml
cp "$ROOT/configs/alertmanager/alertmanager.yml" /etc/prometheus/alertmanager.yml 2>/dev/null || true
[ -f /etc/prometheus/file-sd/office/lan.json ] || cp "$ROOT/configs/prometheus/file-sd/office/lan.json" /etc/prometheus/file-sd/office/lan.json
sed -i "s|OFFICE_SUBNET_PLACEHOLDER|${OFFICE_SUBNET}.0/24|" /etc/prometheus/file-sd/office/lan.json 2>/dev/null || true
chown -R prometheus:prometheus /etc/prometheus
systemctl enable --now prometheus prometheus-node-exporter prometheus-alertmanager

# --- 5. Grafana --------------------------------------------------------------
# БАГ v4.1: apt.grafana.com может отдавать 403 с некоторых IP → fallback на
# dl.grafana.com (.deb), недостающая musl добирается через apt-get install -f.
# Плагин: CLI ищем в обоих форматах (grafana-cli или «grafana cli»).
# ДАТАСОРС ОБЯЗАН иметь uid: prometheus (иначе «No data» на всех дашбордах).
echo "=== 5. Grafana ${GRAFANA_VERSION} ==="
if ! systemctl is-active --quiet grafana-server 2>/dev/null; then
    mkdir -p /usr/share/keyrings
    if wget -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key && [ -s /usr/share/keyrings/grafana.key ]; then
        echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
        apt update
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y grafana; then
        echo "apt-репозиторий Grafana недоступен — скачиваю .deb с dl.grafana.com"
        rm -f /tmp/grafana.deb
        wget -O /tmp/grafana.deb "https://dl.grafana.com/oss/release/grafana_${GRAFANA_VERSION}_amd64.deb"
        dpkg -i /tmp/grafana.deb || apt-get install -f -y
    fi
fi
GCLI=$(command -v grafana-cli || true)
GBIN="/usr/share/grafana/bin/grafana"
if [ -n "$GCLI" ]; then
    "$GCLI" plugins install alexanderzobnin-zabbix-app || true
elif [ -x "$GBIN" ]; then
    "$GBIN" cli plugins install alexanderzobnin-zabbix-app || true
fi
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /etc/grafana/dashboards
cp "$ROOT/configs/grafana/provisioning/datasources/datasources.yml" /etc/grafana/provisioning/datasources/datasources.yml
cp "$ROOT/configs/grafana/provisioning/dashboards/dashboards.yml"   /etc/grafana/provisioning/dashboards/dashboards.yml
cp "$ROOT"/configs/grafana/dashboards/*.json /etc/grafana/dashboards/
systemctl enable grafana-server
systemctl restart grafana-server

# Dynamic Text (панель статуса дашборда) — неподписанный плагин + HTML без
# санитизации: systemd-override с переменными окружения (надёжнее ini).
mkdir -p /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/dynamictext.conf <<'EOF'
[Service]
Environment=GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=marcusolsson-dynamictext-panel
Environment=GF_PANELS_DISABLE_SANITIZE_HTML=true
EOF
systemctl daemon-reload
systemctl restart grafana-server

# --- 6. MAX webhook ------------------------------------------------------------
echo "=== 6. MAX webhook ==="
mkdir -p /opt/monitoring/webhook
install -m 755 "$ROOT/webhook/max-webhook-server.py" /opt/monitoring/webhook/max-webhook-server.py
[ -f /etc/default/max-webhook-server ] || cat > /etc/default/max-webhook-server <<EOF
# ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ:
MAX_BOT_TOKEN=YOUR_BOT_TOKEN_HERE
MAX_API_URL=https://platform-api.max.ru/messages
MAX_CHAT_ID=YOUR_CHAT_ID
WEBHOOK_PORT=5000
LOG_FILE=/var/log/max-webhook-server.log
EOF
install -m 644 "$ROOT/webhook/max-webhook-server.service" /etc/systemd/system/max-webhook-server.service
systemctl daemon-reload
systemctl enable --now max-webhook-server

# --- 7. Сканеры -----------------------------------------------------------------
# Конфиги НЕ перезаписываем, если существуют (баг v4.1: затёр реальный офис).
# Примерных филиалов в branches.conf НЕТ — иначе сканер создаёт фантомные таргеты.
echo "=== 7. Сканеры сети ==="
mkdir -p /etc/zabbix-monitor /var/log/zabbix
[ -f /etc/zabbix-monitor/branches.conf ] || printf '# Филиалы: <city> <подсеть без последнего октета> <region>\n# Пример (раскомментируйте):\n# msk 10.50.1 moscow\n' > /etc/zabbix-monitor/branches.conf
[ -f /etc/zabbix-monitor/office.conf ] || echo "OFFICE_SUBNET=${OFFICE_SUBNET}" > /etc/zabbix-monitor/office.conf
for u in scanner-office scanner-branches; do
    install -m 644 "$ROOT/systemd/$u.service" /etc/systemd/system/$u.service
    install -m 644 "$ROOT/systemd/$u.timer"   /etc/systemd/system/$u.timer
done
systemctl daemon-reload
systemctl enable --now scanner-office.timer scanner-branches.timer
systemctl start scanner-office.service || true

# --- 8. Сервисы Zabbix -----------------------------------------------------------
echo "=== 8. Сервисы Zabbix ==="
systemctl enable --now mysql zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2

# --- Готово -----------------------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "=== ВСЁ УСТАНОВЛЕНО ==="
cat <<EOF
Zabbix:       http://${IP}/zabbix
Grafana:      http://${IP}:3000     (первый вход admin/admin — задайте свой пароль)
Prometheus:   http://${IP}:9090
Alertmanager: http://${IP}:9093

Дальше обязательно:
1) nano /etc/default/max-webhook-server   # токен MAX-бота и chat_id
   curl http://localhost:5000/test        # тестовое сообщение в MAX
2) Впишите API-токены BliKVM в /etc/prometheus/prometheus.yml
   (веб-морда BliKVM → Управление аккаунтом → Мои токены API, scope «Мониторинг»)
   и выполните: systemctl reload prometheus
3) Пройдите мастер Zabbix: БД zabbix / пользователь zabbix / пароль ${DB_PASSWORD}
4) Финальная проверка: ./scripts/test-all.sh → ждём Passed 20, Failed 0
EOF
