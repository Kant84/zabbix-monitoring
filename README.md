# Universal Monitoring Stack v4.1

Полный стек мониторинга инфраструктуры: **Zabbix + Prometheus + Alertmanager + Grafana + MAX Messenger**.

Сервер работает на Ubuntu/Debian. Агенты — Linux (Ubuntu 22.04–24.04, Debian 11–13) и Windows 10–11.
**Никаких зашитых IP в коде:** Prometheus получает цели через `file_sd` (JSON-файлы),
которые автоматически обновляют сканеры (филиалы + офисный LAN).

---

## 1. Архитектура

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    server-01 (ЦЕНТРАЛЬНЫЙ СЕРВЕР)                        │
│                                                                          │
│  Zabbix Server :10051  │  Prometheus :9090  │  Alertmanager :9093       │
│  Grafana :3000         │  MAX Webhook :5000 │  Node Exporter :9100      │
│                                                                          │
│  Сканеры (systemd timers):                                              │
│    scanner-branches.timer  — каждые 30 мин (филиалы РФ)                  │
│    scanner-office.timer    — каждые 10 мин (офисный LAN)                │
│                                                                          │
│  Prometheus targets ← /etc/prometheus/file-sd/**/*.json (обновляются   │
│  сканерами автоматически, refresh_interval 30s)                          │
└──────────────┬───────────────────────────────────────────┬───────────────┘
               │                                          │
     ┌─────────▼──────────┐                    ┌──────────▼─────────┐
     │  ФИЛИАЛЫ ПО РФ     │                    │  ОФИС (LAN)         │
     │  Любое количество, │                    │  Все машины         │
     │  задаются конфигом │                    │  сканируются по ARP │
     │  /etc/zabbix-      │                    │  + ping + SSH       │
     │  monitor/branches  │                    │                     │
     │  .conf             │                    │                     │
     └────────────────────┘                    └─────────────────────┘
               │                                          │
               └──────────────┬───────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  MAX Messenger     │
                    └───────────────────┘
```

### Принцип работы

| Шаг | Что происходит |
|-----|----------------|
| 1 | Prometheus стартует и читает `file-sd/branches/*.json` + `file-sd/office/*.json` |
| 2 | Каждые 30 мин `scanner-branches.timer` пингует подсети филиалов → находит `:9100` (node_exporter) → обновляет JSON → регистрирует хост в Zabbix через API |
| 3 | Каждые 10 мин `scanner-office.timer` сканирует офис (ARP + ping + порты 9100/10050) → обновляет `office/lan.json` |
| 4 | Новые хосты появляются в Prometheus и Grafana **автоматически** через 30 сек |
| 5 | Alertmanager получает алерты → Webhook-сервер → MAX Messenger + Email |

### Цветовая схема алертов

| Индикатор | Значение |
|-----------|----------|
| ☠️ Череп | Сервер недоступен (Disaster) |
| ⚠️ Жёлтый `!` | Критические данные: CPU > 85%, RAM > 90%, Disk > 90% |
| 🟢 | Всё в норме |

---

## 2. Структура проекта

```
zabbix-monitoring-project/
├── .gitignore
├── README.md                      ← этот файл
├── configs/
│   ├── zabbix/
│   │   ├── zabbix_server.conf
│   │   └── zabbix_agent2.conf
│   ├── prometheus/
│   │   ├── prometheus.yml         ← file_sd, БЕЗ хардкода IP
│   │   ├── alerts.yml             ← правила (ServerDown, HighCPU, HighMemory, DiskFull)
│   │   └── file-sd/
│   │       ├── branches/          ← msk.json spb.json kzn.json nsk.json (примеры)
│   │       └── office/lan.json    ← автозаполняется сканером
│   ├── alertmanager/
│   │   ├── alertmanager.yml
│   │   └── templates/default.tmpl
│   └── grafana/
│       ├── provisioning/          ← datasource и dashboard provider
│       └── dashboards/
│           └── all-servers.json   ← универсальный дашборд (переменная $server)
├── webhook/
│   ├── max-webhook-server.py      ← приём Alertmanager webhook → MAX API
│   ├── requirements.txt
│   └── max-webhook-server.service
├── scripts/
│   ├── install-server.sh          ← полная установка на центральный сервер
│   ├── install-agent.sh           ← агент на Linux (Ubuntu/Debian автоопределение)
│   ├── install-office-agent.ps1   ← агент на Windows 10/11
│   ├── scanner-branches.sh        ← сканер филиалов
│   ├── scanner-office.sh          ← сканер офисного LAN
│   ├── import-hosts.sh            ← разовая регистрация хостов в Zabbix
│   └── test-all.sh                ← проверка всех компонентов
├── systemd/
│   ├── scanner-branches.service / .timer
│   └── scanner-office.service / .timer
├── packaging/
│   ├── DEBIAN/                    ← control + postinst
│   └── build-deb.sh               ← сборка .deb
└── docs/
    ├── INSTALL.md
    └── API-REFERENCE.md
```

---

## 3. Требования

### Центральный сервер (server-01)

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| ОС | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU | 2 ядра | 4 ядра |
| RAM | 4 GB | 8 GB |
| Диск | 40 GB | 100 GB SSD |
| Сеть | 1 Gbps | 1 Gbps |

### Агенты

| ОС | Компоненты |
|----|-----------|
| Ubuntu 22.04 / 24.04 | Zabbix Agent2 + Node Exporter |
| Debian 11 / 12 / 13 | Zabbix Agent2 + Node Exporter |
| Windows 10 / 11 | Zabbix Agent2 (MSI) + windows_exporter |

---

## 4. Установка из Git

### Шаг 4.1 — Залить проект на GitHub (один раз, с рабочей машины Windows)

В PowerShell:

```powershell
# 1. Распакуйте архив проекта, зайдите в папку
cd E:\zabbix-monitoring-project

# 2. Инициализация репозитория
git init
git add .
git commit -m "Monitoring stack v4.1: initial structure"

# 3. Создайте ПУСТОЙ репозиторий на github.com (без README!) и привяжите
git remote add origin https://github.com/<ваш-аккаунт>/zabbix-monitoring-project.git
git branch -M main
git push -u origin main
```

> Маркер успеха: на GitHub видны все файлы и папки, в том числе `configs/prometheus/file-sd/`.

### Шаг 4.2 — Установка на центральный сервер

На server-01 (под root):

```bash
# 1. Клонируем репозиторий
apt update && apt install -y git
git clone https://github.com/<ваш-аккаунт>/zabbix-monitoring-project.git /opt/monitoring

# 2. Права на скрипты
cd /opt/monitoring
chmod +x scripts/*.sh

# 3. Запуск полной установки (Zabbix + MySQL + Prometheus + Alertmanager + Grafana + Webhook)
./scripts/install-server.sh
```

> Маркер успеха — вывод скрипта в конце:
> ```
> Zabbix:    http://<IP>/zabbix
> Grafana:   http://<IP>:3000
> Prometheus:http://<IP>:9090
> ```

### Шаг 4.3 — Настройка MAX Messenger

```bash
# 1. Отредактируйте конфиг, вставьте токен бота и chat_id
nano /etc/default/max-webhook-server

# 2. Перезапуск webhook-сервера
systemctl restart max-webhook-server

# 3. Тестовое сообщение в MAX
curl http://localhost:5000/test
```

> Маркер успеха: в MAX пришло тестовое оповещение `TestAlert`.

### Шаг 4.4 — Настройка филиалов

Подсети филиалов задаются в конфиге, **не в коде**:

```bash
# 1. Создайте конфиг с реальными подсетями
mkdir -p /etc/zabbix-monitor
cat > /etc/zabbix-monitor/branches.conf <<'EOF'
# Формат: <city> <подсеть-без-последнего-октета> <region>
# Пример ниже — замените на реальные подсети!
msk 10.200.1 moscow
spb 10.200.2 northwest
kzn 10.200.3 volga
nsk 10.200.4 siberia
EOF

# 2. Первый запуск сканера вручную
/opt/monitoring/scripts/scanner-branches.sh

# 3. Проверка — targets должны появиться
cat /etc/prometheus/file-sd/branches/*.json
```

> Маркер успеха: в `branches/*.json` появились живые `targets`, в Prometheus (Status → Targets) все `UP`.

### Шаг 4.5 — Офисный LAN

```bash
# Подсеть офиса (по умолчанию 10.100.0, переопределяется переменной)
echo 'OFFICE_SUBNET=192.168.1' > /etc/zabbix-monitor/office.conf   # пример

/opt/monitoring/scripts/scanner-office.sh
cat /etc/prometheus/file-sd/office/lan.json
```

### Шаг 4.6 — Windows-машины офиса

На каждой Windows 10/11 машине в PowerShell **от администратора**:

```powershell
# Скачать скрипт из репозитория или скопировать
.\install-office-agent.ps1 -ZabbixServer "192.168.1.10"   # IP центрального сервера
```

Скрипт установит Zabbix Agent2 и windows_exporter, откроет порт 10050 в брандмауэре.

### Шаг 4.7 — Регистрация хостов в Zabbix (разово, для уже известных машин)

```bash
./scripts/import-hosts.sh
```

> Маркер успеха: в Zabbix (Monitoring → Hosts) видны все хосты со статусом Enabled.

### Шаг 4.8 — Grafana

1. Откройте `http://<IP>:3000` (admin/admin → смените пароль).
2. Provisioning подцепит Zabbix datasource и дашборд `All Servers` автоматически.
3. Если datasource не подхватился: **Connections → Data Sources → Zabbix**, URL `http://localhost/zabbix`, логин `Admin` / `zabbix` → Save & Test.

### Шаг 4.9 — Финальная проверка

```bash
./scripts/test-all.sh
```

> Маркер успеха: `Passed: 12+  Failed: 0`.

---

## 5. Эксплуатация

### Добавить новый филиал

Одна строка в `/etc/zabbix-monitor/branches.conf`:

```
ekb 10.200.5 ural
```

Всё остальное (Prometheus targets, Zabbix-регистрация) произойдёт автоматически в течение 30 минут.

### Логи

| Компонент | Лог |
|-----------|-----|
| Zabbix Server | `/var/log/zabbix/zabbix_server.log` |
| Zabbix Agent2 | `/var/log/zabbix/zabbix_agent2.log` |
| Сканеры | `/var/log/zabbix/scanner-*.log` |
| Webhook | `/var/log/max-webhook-server.log` |
| Prometheus/Alertmanager/Grafana | `journalctl -u <имя>` |

### Обновление проекта с Git

```bash
cd /opt/monitoring && git pull
systemctl restart max-webhook-server
```

### Сборка .deb пакета

```bash
cd /opt/monitoring
./packaging/build-deb.sh
# Результат: zabbix-universal-monitor_<версия>.deb
```

---

## 6. Безопасность

- Пароль БД Zabbix меняется в `configs/zabbix/zabbix_server.conf` **до** установки (и в `install-server.sh`).
- Токен MAX хранится только в `/etc/default/max-webhook-server` (не в репозитории!).
- В `.gitignore` исключены `.env`, логи, архивы — секреты не попадут в Git.
- Порты наружу открывать не нужно: сервер сам подключается к филиалам; филиалы достаточно видеть через VPN/LAN.

---

## 7. Траблшутинг

| Симптом | Причина | Решение |
|---------|---------|---------|
| Targets `DOWN` в Prometheus | Нет node_exporter на хосте | `apt install prometheus-node-exporter` или скрипт установки агента |
| Хост не появляется в Zabbix | Сканер не видит порт 10050 | Проверить `systemctl status zabbix-agent2` на хосте и firewall |
| Тест `/test` не шлёт в MAX | Неверный токен/chat_id | `journalctl -u max-webhook-server -n 50` |
| Webhook 500 | Flask не стартует | `systemctl status max-webhook-server`, проверить `/etc/default/max-webhook-server` |
| Grafana пустая | Datasource не настроен | Проверить provisioning в `/etc/grafana/provisioning/` |


git clone https://github.com/Kant84/zabbix-monitoring-project.git /opt/monitoring
cd /opt/monitoring && chmod +x scripts/*.sh
./scripts/install-server.sh          # Zabbix+MySQL+Prometheus+Alertmanager+Grafana+Webhook+таймеры сканеров
nano /etc/default/max-webhook-server # вставь токен MAX
curl http://localhost:5000/test      # тестовое сообщение в MAX
./scripts/test-all.sh                # финальная проверка: Passed 14, Failed 0
---

*Версия 4.1.0 | Поддержка: Ubuntu 22.04–24.04, Debian 11–13, Windows 10–11 (агенты)*
