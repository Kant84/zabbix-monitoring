# Universal Monitoring Stack v4.2

Мониторинг инфраструктуры офиса и филиалов: **Zabbix 7.0 + MySQL + Prometheus +
Alertmanager + Grafana + webhook-оповещения в MAX**. Обнаружение хостов сканерами
сети (без хардкода IP), дашборд «All Servers» (Linux-хосты + BliKVM), алерты
☠️/⚠️ в мессенджер и на почту.

> v4.2 (17.11.2026) — battle-tested: все найденные «в бою» баги v4.1 исправлены,
> добавлен мониторинг BliKVM, двусторонний установщик агентов, развёрнутый README.

---

## 1. Архитектура

```
                    ┌────────────────────── СЕРВЕР МОНИТОРИНГА ──────────────────────┐
                    │  monitor (192.168.88.36):                                       │
                    │                                                               │
 жильцы офиса  ───► │  scanner-office.timer ──► file-sd/office/lan.json ──┐         │
 (ping+порт 9100)   │  scanner-branches.timer ─► file-sd/branches/*.json ──┼──► Prometheus ──► Alertmanager ──► MAX webhook ──► MAX
                    │                                                       │     (job node, blikvm-42/44)      (alerts.yml)
 Linux-хосты       │  zabbix-agent2 (10051) ──► Zabbix Server ──► MySQL    │            │
 (офис+филиалы)     │  Grafana :3000 ◄── provisioning (datasources, dashboards)         │
                    │  node_exporter (:9100) на каждом Linux-хосте ◄───────────────────┘
                    └───────────────────────────────────────────────────────────────
 BliKVM .42/.44 ────► /api/v1/prometheus/metrics (Bearer API-токен) ──► job blikvm-42/44
```

- **Новый Linux-хост** в офисе: поставил агент → сканер сам нашёл за ≤10 мин → в Grafana.
- **Новый филиал**: одна строка в `branches.conf` → сканер обходит подсеть.
- **Новый BliKVM**: токен в `prometheus.yml` → метрики и алерты.

---

## 2. Требования

| | |
|---|---|
| Сервер | Ubuntu 22.04/24.04, 4+ ГБ RAM, 20+ ГБ диск, статический IP в офисном LAN |
| Сеть | Сервер ДОЛЖЕН быть внутри мониторимого LAN (агенты/SNMP ходят локально) |
| Доступ | root (sudo) на сервере; SSH с sudo на хосты-агенты (для push-режима) |
| MAX | бот и chat_id (получение — ниже) |

---

## 3. Установка сервера (из Git)

### Шаг 3.1 — клонирование

```bash
sudo apt update && sudo apt install -y git
sudo git clone https://github.com/Kant84/zabbix-monitoring.git /opt/monitoring
sudo chown -R $USER:$USER /opt/monitoring
cd /opt/monitoring && chmod +x scripts/*.sh
```

**Ожидаемый вывод:**
```
Cloning into '/opt/monitoring'...
remote: Enumerating objects: ...
Receiving objects: 100% ...
```
`ls /opt/monitoring` → `configs  docs  packaging  README.md  scripts  systemd  webhook`

### Шаг 3.2 — установка стека

```bash
sudo ./scripts/install-server.sh
```

**Что делает (по секциям вывода):**
1. **Репозиторий Zabbix** — качает `zabbix-release_latest+ubuntu22.04_all.deb`
   (имя из ID+VERSION_ID ОС, а не кодовое «jammy»; путь без `/release/`).
   Ожидается: `... saved [8368/8368]`.
2. **Пакеты** — apt ставит MySQL, Zabbix server/frontend/agent2, Prometheus,
   Alertmanager, node-exporter, python3-flask. 5–10 минут.
   Ожидается: `0 upgraded, N newly installed ...` без красных `E:`.
3. **MySQL** — создаёт БД `zabbix`, пользователя, **ищет файл схемы через
   `dpkg -L`** (путь отличается между версиями!), включает
   `log_bin_trust_function_creators` (иначе MySQL 8 ругается ERROR 1419 на
   создание функций схемы) и импортирует схему **один раз**
   (повторный запуск видит таблицы и пропускает).
   Ожидается: `Импорт схемы из /usr/share/zabbix-sql-scripts/mysql/server.sql.gz ...`
   затем `Схема импортирована.`
4. **Prometheus/Alertmanager** — конфиги из репо, каталоги file-sd.
5. **Grafana** — сначала пробует apt-репозиторий; если `apt.grafana.com` отдаёт
   403 (региональная блокировка CDN) — автоматически качает `.deb` с
   `dl.grafana.com` и добирает зависимость `musl` через `apt-get install -f`.
   Затем ставит плагин Zabbix (сам ищет CLI: `grafana-cli` или `grafana cli`).
   ⚠ В provisioning datasource Prometheus имеет **`uid: prometheus`** —
   без него все дашборды покажут «No data».
6. **MAX webhook** — сервис на :5000; конфиг-заглушка `/etc/default/max-webhook-server`
   **не перезаписывается**, если уже существует.
7. **Сканеры** — таймеры systemd; `branches.conf`/`office.conf` не затираются.
8. **Итог** — сводка URL:
```
=== ВСЁ УСТАНОВЛЕНО ===
Zabbix:       http://192.168.88.36/zabbix
Grafana:      http://192.168.88.36:3000
Prometheus:   http://192.168.88.36:9090
Alertmanager: http://192.168.88.36:9093
```

### Шаг 3.3 — мастер Zabbix (в браузере)

Откройте `http://<IP>/zabbix`:

| Поле | Значение |
|---|---|
| Тип БД | MySQL |
| Хост БД | `localhost` |
| Порт | `0` |
| Имя БД | `zabbix` |
| Пользователь | `zabbix` |
| **Пароль** | `zabbix_password_change_me` (или ваш `DB_PASSWORD`) |
| TLS | не трогать |

Далее: имя сервера `monitor`, часовой пояс `Europe/Moscow` → «Установить» →
вход **Admin / zabbix** (пароль смените: User settings → Change password).

⚠ **Частая ошибка** «Доступ запрещен (пароль: ДА)» — опечатка в пароле.
Проверка с сервера:
```bash
mysql -uzabbix -pzabbix_password_change_me zabbix -e "select 1" && echo AUTH_OK
```

### Шаг 3.4 — токен MAX и тест оповещений

1. Создайте бота в MAX (Bot Platform), напишите ему любое сообщение с телефона.
2. Получите chat_id:
```bash
curl -s -H "Authorization: <ТОКЕН_БОТА>" "https://platform-api.max.ru/updates?limit=5"
```
В JSON ищите `"chat_id": <число>`.
3. Впишите значения:
```bash
sudo nano /etc/default/max-webhook-server
# MAX_BOT_TOKEN=...   MAX_CHAT_ID=...
sudo systemctl restart max-webhook-server
```
4. Тест:
```bash
curl -s http://localhost:5000/test
```
**Ожидается:** `{"detail":"OK",...,"success":true}` и сообщение 🔥 TestAlert в MAX.

### Шаг 3.5 — финальная проверка

```bash
./scripts/test-all.sh
```
**Ожидается:** `Passed: 20  Failed: 0` (единственный допустимый FAIL до шага 3.4 —
«MAX token set»).

---

## 4. BliKVM (KVM-over-IP) в мониторинге

У BliKVM есть нативные метрики `/api/v1/prometheus/metrics`, но доступ — по
**API-токену** (не паролю веб-морды!).

1. Веб-морда BliKVM → **Управление аккаунтом → Мои токены API → Создать токен API**
   → обязательно разрешение **«Мониторинг»** (токен без него даёт HTTP 403).
   Сделайте на каждом устройстве (токены разные).
2. Впишите в `/etc/prometheus/prometheus.yml` вместо
   `YOUR_BLIKVM_TOKEN_42` / `YOUR_BLIKVM_TOKEN_44`, при необходимости поправьте IP:
```bash
sudo sed -i 's|YOUR_BLIKVM_TOKEN_42|bkv_api_...|' /etc/prometheus/prometheus.yml
sudo sed -i 's|YOUR_BLIKVM_TOKEN_44|bkv_api_...|' /etc/prometheus/prometheus.yml
sudo promtool check config /etc/prometheus/prometheus.yml | tail -1   # SUCCESS
sudo systemctl reload prometheus
```
3. Проверка (две строки — метрики текут):
```bash
curl -s "localhost:9090/api/v1/query?query=blikvm_temperature_c" | python3 -c "import json,sys; [print(r['metric'].get('instance'), r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
```
Алерты: **BliKvmDown / BliKvmHighTemp (>60°C) / BliKvmLowMem**.

> ⚠ `blikvm_storage_available_bytes` всегда 0 — и это НЕ баг: корневой раздел
> BliKVM (116 МБ) — это образ системы, он штатно заполнен на 100%. Пользовательские
> данные живут на разделе `/data` (проверено: 26 ГБ свободно) и отдельной метрикой
> не сдаются. Алерта на storage нет (убран в v4.2.1 — был бы вечным ложным).

---

## 5. Агенты на Linux-хосты (двусторонний install-agent.sh)

### Режим 1 — локально (на самой машине-агенте)

```bash
sudo bash /tmp/install-agent.sh --server 192.168.88.36 --name mobile
```
**Ожидаемый вывод:**
```
=== ОС: Ubuntu 24.04.4 LTS ===
... saved [8368/8368]
=== Агент установлен ===
Zabbix Server: 192.168.88.36
Hostname:      mobile
Порты:         10050 (agent), 9100 (node_exporter)
```
Через ≤10 минут хост появится на дашборде (сканер офиса подхватит порт 9100).

### Режим 2 — push с сервера мониторинга (одной командой на всю сеть)

```bash
sudo ./install-agent.sh --push --server 192.168.88.36 --user nfc     --targets "192.168.88.43:mobile 192.168.88.45:mobile1 192.168.88.35:nfc35"
```
Скрипт сам копирует себя на каждую машину (scp) и запускает там от root (ssh+sudo).
**Маркер завершения:** по каждой цели блок `=== <ip> (<name>) ===` + сводка
`=== Агент установлен ===`, в конце — `=== PUSH завершён ===`.

### Windows-машины офиса

```powershell
.\scripts\install-office-agent.ps1 -Server 192.168.88.36
```
(скачивает zabbix-agent2 MSI + windows_exporter, открывает порты брандмауэра)

---

## 6. Эксплуатация

| Что | Где |
|---|---|
| Список филиалов | `/etc/zabbix-monitor/branches.conf` (`msk 10.50.1 moscow` — одна строка = филиал) |
| Подсеть офиса | `/etc/zabbix-monitor/office.conf` (`OFFICE_SUBNET=192.168.88`) |
| Токен MAX | `/etc/default/max-webhook-server` |
| Токены BliKVM | `/etc/prometheus/prometheus.yml` (строки credentials) |
| Алерты | `/etc/prometheus/alerts.yml` |
| Дашборды | `/etc/grafana/dashboards/*.json` (провижнинг перечитывает за 30 с) |

Полезные команды:
```bash
./scripts/test-all.sh                          # здоровье всего стека
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
curl -s localhost:9090/api/v1/alerts           # активные/висящие алерты
journalctl -u prometheus -u grafana-server --since "-10min" --no-pager
```

---

## 7. Траблшутинг (симптом → причина → лечение)

| Симптом | Причина | Лечение |
|---|---|---|
| Скрипт «завис» после строки «Проверка доступности репозитория Zabbix» и вышел молча | wget 404 (был неверный URL в v4.1) | v4.2 чинит; вручную: `wget -O /tmp/zabbix-release.deb "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu22.04_all.deb" && dpkg -i /tmp/zabbix-release.deb` |
| `gzip: .../server.sql.gz: No such file` | В 7.0.32 путь `/usr/share/zabbix-sql-scripts/...` | v4.2 ищет через `dpkg -L`; вручную: `zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \| mysql zabbix` |
| `ERROR 1419 (HY000) ... SUPER privilege` при импорте схемы | MySQL 8 + binlog | `mysql -e "SET GLOBAL log_bin_trust_function_creators=1"` (делает v4.2), либо импорт под root через сокет |
| Grafana «No data» + «Failed to upgrade legacy queries» | У datasource нет `uid: prometheus` | Добавить `uid: prometheus` в provisioning и `systemctl restart grafana-server` |
| Grafana не ставится: `403 Access Denied` с apt.grafana.com | CDN заблокирован для вашего IP | v4.2 сам качает `.deb` с `dl.grafana.com`; вручную: `wget https://dl.grafana.com/oss/release/grafana_11.1.0_amd64.deb && dpkg -i ... && apt-get install -f -y` |
| `grafana: command not found` при установке плагина | CLI лежит не в PATH | v4.2 ищет `/usr/sbin/grafana-cli` и `/usr/share/grafana/bin/grafana cli` |
| BliKVM: 401 Unauthorized | Авторизация не basic, а Bearer-токен | Создать API-токен (scope «Мониторинг»), конфиг `authorization: {type: Bearer, credentials: ...}` |
| BliKVM: 403 | Токен без scope «Мониторинг» | Пересоздать токен с разрешением |
| В targets API «призраки» `http://IP:443/metrics` с job=blikvm | blikvm.json лежит в file-sd/office, job node (glob office/*.json) дублирует его http-скрейпом | Держать таргеты BliKVM в static_configs (как в v4.2), НЕ в file-sd/office |
| Изменения в file-sd/json не подхватываются (старые таргеты висят) | file_sd иногда пропускает fsnotify-событие | `systemctl restart prometheus` (reload может не перечитать) |
| `found multiple scrape configs with job name` | Два job с одинаковым именем запрещены | Дать уникальные имена (blikvm-42/44), алерты ловить `job=~"blikvm.*"` |
| Мусорные 10.200.x.x в дашборде | Примерные филиалы в branches.conf (v4.1) | Очистить conf, удалить json, и **вычистить серии**: включить admin API (`ARGS="--web.enable-admin-api"` в `/etc/default/prometheus`, restart), затем `curl -X POST -g 'localhost:9090/api/v1/admin/tsdb/delete_series?match[]={instance=~"10.200.*"}'`, `curl -X POST localhost:9090/api/v1/admin/tsdb/clean_tombstones`, вернуть ARGS="", restart. Результат проверять ТОЛЬКО через `/api/v1/label/instance/values` (instant query уставшие серии не показывает!) |
| `spb.json` с `"targets": [""]` | scanner-branches v4.1 при пустом результате | Исправлено в v4.2 (пустой результат → файл удаляется) |

---

## 8. Роадмап

- [ ] SNMP MikroTik (шаблон «MikroTik by SNMP»)
- [ ] Blackbox-exporter: ping «чужих» устройств, ICMP+HTTPS для VIP
- [ ] Авто-добавление хостов в Zabbix через API (scanner → host.create)
- [ ] Разбор `blikvm_storage_available_bytes = 0` (баг прошивки?)
- [ ] Экспортёр PostgreSQL для HA-пары (репликация, слоты)
