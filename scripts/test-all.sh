#!/bin/bash
# Проверка всех компонентов стека
set -e
PASS=0; FAIL=0
check() {
    if eval "$2" > /dev/null 2>&1; then
        echo -e "\033[32m✓ PASS\033[0m: $1"; PASS=$((PASS+1))
    else
        echo -e "\033[31m✗ FAIL\033[0m: $1"; FAIL=$((FAIL+1))
    fi
}

echo "=== Services ==="
check "Zabbix Server"        "systemctl is-active zabbix-server"
check "Zabbix Agent2"        "systemctl is-active zabbix-agent2"
check "Prometheus"           "systemctl is-active prometheus"
check "Alertmanager"         "systemctl is-active prometheus-alertmanager"
check "Grafana"              "systemctl is-active grafana-server"
check "MAX Webhook"          "systemctl is-active max-webhook-server"
check "Node Exporter"        "systemctl is-active prometheus-node-exporter"
check "Scanner branches"     "systemctl is-active scanner-branches.timer"
check "Scanner office"       "systemctl is-active scanner-office.timer"

echo ""
echo "=== Endpoints ==="
check "Zabbix Frontend"      "curl -s -o /dev/null http://localhost/zabbix"
check "Zabbix API"           "curl -s -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"apiinfo.version\",\"params\":[],\"id\":1}' http://localhost/zabbix/api_jsonrpc.php | grep -q result"
check "Prometheus"           "curl -s -o /dev/null http://localhost:9090"
check "Alertmanager"         "curl -s -o /dev/null http://localhost:9093"
check "Grafana"              "curl -s -o /dev/null http://localhost:3000"
check "Webhook health"       "curl -s http://localhost:5000/ | grep -q ok"
check "Node Exporter"        "curl -s http://localhost:9100/metrics | grep -q node_cpu"

echo ""
echo "=== Configs ==="
check "file-sd branches"     "ls /etc/prometheus/file-sd/branches/*.json"
check "file-sd office"       "test -f /etc/prometheus/file-sd/office/lan.json"
check "branches.conf"        "test -f /etc/zabbix-monitor/branches.conf"
check "MAX token set"        "! grep -q YOUR_BOT_TOKEN /etc/default/max-webhook-server"

echo ""
echo -e "\033[32mPassed: $PASS\033[0m  \033[31mFailed: $FAIL\033[0m"
[ "$FAIL" -eq 0 ] || exit 1
