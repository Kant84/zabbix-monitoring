# INSTALL — детальная установка

См. корневой README.md, раздел 4 «Установка из Git». Здесь — дополнения.

## Переменные окружения сканеров

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| BRANCHES_CONF | /etc/zabbix-monitor/branches.conf | Список филиалов |
| OFFICE_CONF | /etc/zabbix-monitor/office.conf | Подсеть офиса |
| LINUX_TEMPLATE_ID | 10343 | Шаблон Zabbix для Linux-хостов |
| ZABBIX_USER / ZABBIX_PASS | Admin / zabbix | Доступ в API Zabbix |
| DB_PASSWORD | zabbix_password_change_me | Пароль БД (только при install-server.sh) |

## Как узнать ID шаблона Linux

```bash
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json'       -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}'       http://localhost/zabbix/api_jsonrpc.php | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
curl -s -X POST -H 'Content-Type: application/json' -d "{
  "jsonrpc":"2.0","method":"template.get",
  "params":{"filter":{"host":"Linux by Zabbix agent active"},"output":["templateid"]},
  "auth":"$TOKEN","id":1}" http://localhost/zabbix/api_jsonrpc.php
```

Если ID отличается от 10343 — задайте переменную LINUX_TEMPLATE_ID.

## Autoregistration (для серверов за NAT/VPN с динамическими IP)

Если филиалы сами стучатся на сервер (agent → server), настройте в Zabbix:
**Configuration → Actions → Autoregistration actions**:
- Condition: Host metadata contains "Linux"
- Operations: Add host → Add to group "Discovered hosts" → Link template "Linux by Zabbix agent active"

На агенте филиала:
```ini
ServerActive=<домен или IP сервера>:10051
Hostname=branch-ekb-01
HostMetadata=Linux branch-ekb
```
