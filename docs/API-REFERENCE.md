# API Reference

## Zabbix API

Базовый URL: `http://<server>/zabbix/api_jsonrpc.php`

### Авторизация
```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{
  "jsonrpc":"2.0","method":"user.login",
  "params":{"username":"Admin","password":"zabbix"},"id":1
}' http://localhost/zabbix/api_jsonrpc.php
```

### Список хостов
```bash
curl -s -X POST -H 'Content-Type: application/json' -d "{
  "jsonrpc":"2.0","method":"host.get",
  "params":{"output":["hostid","host","available"],
              "selectInterfaces":["ip"]},
  "auth":"$TOKEN","id":1
}" http://localhost/zabbix/api_jsonrpc.php
```

### Создание хоста
```bash
curl -s -X POST -H 'Content-Type: application/json' -d "{
  "jsonrpc":"2.0","method":"host.create",
  "params":{
    "host":"new-host",
    "interfaces":[{"type":1,"main":1,"useip":1,"ip":"10.0.0.50","dns":"","port":"10050"}],
    "groups":[{"groupid":"2"}],
    "templates":[{"templateid":"10343"}]
  },
  "auth":"$TOKEN","id":1
}" http://localhost/zabbix/api_jsonrpc.php
```

## MAX Webhook API

| Endpoint | Метод | Назначение |
|----------|-------|------------|
| `/` | GET | health-check |
| `/webhook` | POST | приём Alertmanager webhook |
| `/test` | GET | тестовое сообщение в MAX |

### Пример Alertmanager webhook
```json
POST /webhook
{"status":"firing","alerts":[{"labels":{"alertname":"ServerDown","instance":"10.0.0.5:9100","severity":"critical"},"annotations":{"description":"Нет метрик более 2 минут"}}]}
```

## Prometheus API

- Targets: `http://localhost:9090/api/v1/targets`
- Alerts: `http://localhost:9090/api/v1/alerts`
- Query: `http://localhost:9090/api/v1/query?query=up`
