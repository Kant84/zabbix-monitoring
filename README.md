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
Алерты: **BliKvmDown / BliKvmHighTemp (>60°C) / BliKvmLowMem**. Напоминания по BliKVM — раз в 8 ч (отдельный маршрут `match_re: alertname: BliKvm.*` в alertmanager.yml, v4.2.4); серверные алерты — без изменений (critical 30 мин / high 1 ч / warning 4 ч).

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

### Клубы с публичным IP (по всей России, без доступа к офисному Mikrotik)

Схема «офис сам ходит к клубу» (passive-проверки). Понадобится: доступ по SSH
на клубный сервер и **один раз** — проброс двух портов на роутере КЛУБА
(внешний порт = внутренний!, на внутренний IP сервера):

| Внешний порт | Куда | Для чего |
|---|---|---|
| TCP 9100 | `<внутр.IP клуба>:9100` | node_exporter: метрики → Grafana |
| TCP 10050 | `<внутр.IP клуба>:10050` | zabbix-agent2: опрос Zabbix (PSK) |
| TCP 9633 | `<внутр.IP клуба>:9633` | smartctl_exporter: SMART дисков (SSD Health) |

Один скрипт со стороны мониторинга: `sudo ./scripts/connect-club.sh --name club-<city> --ip <публичный IP>`
(стадия 2 — установка на сервер клуба: `sudo bash club-bootstrap.sh --server <белый IP офиса> --name club-<city>-<short> --psk <PSK>` — ставит агент, SMART, SSH-наблюдение и СКУД-пробник одним запуском)
(регистрирует хост, добавляет в сканер SMART и печатает команды для сервера клуба).

Заодно сделай на роутере клуба **резервирование DHCP** для сервера (привязка
по MAC), чтобы внутренний IP не менялся.

**1. На сервере мониторинга** — регистрация хоста (PSK генерируется сам):
```bash
./scripts/add-club-host.sh --name club-nn-fizra --ip 5.227.70.150
```
**2. На клубном сервере:**
```bash
wget -q https://raw.githubusercontent.com/Kant84/zabbix-monitoring/main/scripts/install-agent.sh
sudo bash install-agent.sh --passive-only --server <белый IP офиса> --name club-nn-fizra --psk <PSK из шага 1>
```
**3. На клубе — файрвол** (только IP офиса, остальным DROP):
```bash
sudo iptables -I INPUT 1 -p tcp --dport <SSH-порт> -j ACCEPT   # СНАЧАЛА свой SSH!
sudo iptables -I INPUT 2 -p tcp -s <белый IP офиса> --dport 10050 -j ACCEPT
sudo iptables -I INPUT 3 -p tcp -s <белый IP офиса> --dport 9100 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 10050 -j DROP
sudo iptables -A INPUT -p tcp --dport 9100 -j DROP
sudo apt install -y iptables-persistent     # сохранить правила
```
**4. На сервере мониторинга** — Prometheus-таргет (3 строки в job `node`,
отступ 4 пробела у `static_configs:`):
```yaml
    static_configs:
      - targets: ['<IP клуба>:9100']
        labels: {club: '<city-name>', location_type: 'branch'}
```
затем `sudo promtool check config /etc/prometheus/prometheus.yml | tail -1` →
`SUCCESS`, `sudo systemctl reload prometheus`.

**Проверка:** `nc -z -w3 <IP клуба> 9100` → OPEN; в Zabbix хост → Available;
в Grafana «All Servers» появляется плашка клуба.

### Здоровье железа и служб (v4.2.5, install-addon.sh)

Самоопределение — не нужно знать имена служб или дисков:

```bash
sudo ./scripts/install-addon.sh --smart --systemd          # на каждом сервере
# или сразу на все офисные машины:
sudo ./scripts/install-addon.sh --push --user nfc --targets \
    "192.168.88.36:monitor 192.168.88.43:mobile 192.168.88.45:mobile1 192.168.88.35:nfc35"
```

- `--smart` — smartctl_exporter (порт 9633): SMART всех дисков (health, температура,
  атрибуты/износ — диски определяет сам smartctl). На monitor'е также:
  `echo '192.168.88' > /etc/zabbix-monitor/smart.conf` + включить scanner-smart.timer
  (сканер сам найдёт все 9633 в сети).
- `--systemd` — коллектор systemd в node_exporter: метрика состояния **всех** служб.
  Алерт `SystemdServiceFailed` сработает на любую упавшую службу (1С, СКУД — где бы
  они ни стояли) и пришлёт её имя. Дополнительно на серверах с критичными службами:
  `systemctl list-units --type=service --state=running | grep -iE '1c|скуд|zookeeper'`
  — имена появятся в алертах автоматически.
- Алерты: SmartDeviceUnhealthy (SMART FAILED), SmartDeviceHot (>60°C),
  SystemdServiceFailed. Без ручного перечисления имён.

### СКУД клубов (v4.3.0, scripts/skud-probe.py)

Пробник живёт **на сервере клуба** (видит его LAN): HTTP-проверки веб-панелей
(:8585, терминалы :9000) + служба itcservice -> textfile -> порт 9100.
Новых пробросов на роутере клуба НЕ нужно. Конфиг `/etc/zabbix-monitor/skud.conf`:

```
service:itcservice
http://127.0.0.1:8585|Веб СКУД (itcservice)
http://192.168.50.28:9000/login|Вход левый (ITC X1)
http://192.168.50.34:9000/login|Вход правый (ITC X1)
http://192.168.50.32:9000/setup|Выход левый (Firefly)
http://192.168.50.85:9000/setup|Выход правый (Firefly)
```

Установка на сервере клуба: `sudo install -m755 skud-probe.py /usr/local/bin/`,
юниты `skud-probe.service/.timer` -> /etc/systemd/system, `systemctl enable --now skud-probe.timer`.
Алерты: SkudServiceDown, SkudHttpDown — с именем клуба и устройства в MAX.

### Безопасность: наблюдение за SSH (v4.2.7, install-security.sh)

**Только наблюдение и оповещения — без банов и блокировок.** Метрики идут по
уже открытому порту 9100 (textfile-коллектор node_exporter, парсинг /var/log/auth.log
раз в минуту) — клубам роутер трогать НЕ нужно.

```bash
sudo ./scripts/install-security.sh                 # локально
sudo ./scripts/install-security.sh --push --user nfc --targets "192.168.88.43:mobile ..."
```

Парсер — `scripts/auth-metrics.py` (Python): читает `/var/log/auth.log` инкрементально,
при его отсутствии — journald (`_COMM=sshd`, полный пересчёт). Файл метрик:
`/var/lib/prometheus/node-exporter/auth.prom`, состояние — `.auth_state.json`.
У node_exporter РОВНО одна строка `ARGS="--collector.textfile.directory=/var/lib/prometheus/node-exporter"`
(скрипт выставляет сам; systemd-коллектор в новых версиях включён по умолчанию).

| Алерт | Когда | Текст |
|---|---|---|
| SshBruteForce | >10 неудачных с ЧУЖОГО IP за 10 мин | IP + подбираемый логин + сервер |
| SshLoginSuccess | любой успешный вход | пользователь + IP + сервер |
| SshRootLogin | вход под root | IP + сервер (критичность high) |

VPN 10.10.1.x и локалки 192.168.x.x — «свои»: опечатки админов не тревожат,
алертит только интернет. Панели «Безопасность» на дашборде: подборы по IP,
журнал входов за 24ч.

### Клуб за NAT без публичного IP

Тогда только active-режим: агент сам стучится в офис — нужен **один проброс на
офисном Mikrotik**: `TCP 10051 → <IP сервера мониторинга>`. Хост создаётся без
`--ip` (`add-club-host.sh --name club-x`) — шаблон active; на клубе:
`install-agent.sh --active --server <белый IP офиса>:10051 --name club-x --psk <PSK>`.
Файрвол клуба не нужен (только исходящий интернет). Метрики Prometheus через
этот вариант не получить — только Zabbix-данные (Zabbix-datasource в Grafana).

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
| `zabbix_agent2: ... open /etc/zabbix/zabbix_agentd.psk: permission denied` (агент в auto-restart) | agent2 работает от user `zabbix`, а PSK записан `root 600` | `chown root:zabbix /etc/zabbix/zabbix_agentd.psk && chmod 640 ...` (исправлено в v4.2.4) |
| `nc` к клубу: `Connection refused` vs тишина/timeout | refused = пакет дошёл, порт не слушает (агент упал / проброс не туда); timeout = дроп по пути (файрвол/роутер) | refused → `systemctl status zabbix-agent2`, `ss -tlnp \| grep 10050`; timeout → смотреть iptables на клубе и проброс на роутере |
| Проброс на роутере клуба сделан, но порты закрыты | внешний и внутренний порт различаются или адрес не тот | порты должны совпадать: 9100→IP:9100, 10050→IP:10050; внутренний IP = адрес сервера в LAN клуба |
| VIP (.50) «не виден» в роутере (DHCP leases/ARP) | VIP keepalived — статика, не DHCP-клиент; в ARP роутера попадает только при транзитном трафике | норма. Проверка: `/ping 192.168.88.50` с Mikrotik. Для WG-доступа пиру хватает AllowedIPs …, 192.168.88.0/24 |
| `found multiple scrape configs with job name` | Два job с одинаковым именем запрещены | Дать уникальные имена (blikvm-42/44), алерты ловить `job=~"blikvm.*"` |
| `node_textfile_scrape_error 1` / `ssh_` метрик нет | текстфайл вне каталога collector'а или битый формат (кавычки в метках) | каталог `--collector.textfile.directory=/var/lib/prometheus/node-exporter` (ровно одна строка ARGS!), валидный prom-формат, перезапуск node_exporter |
| MAX: `401 No access token` / SSL error 60 к api2 | заголовок `Authorization: <сырой токен>` (БЕЗ "Bearer"); домен `platform-api2.max.ru` имеет кривую цепочку | используйте домен `platform-api.max.ru` и токен без префикса Bearer (как в scripts/club-report.sh) |
| Мусорные 10.200.x.x в дашборде | Примерные филиалы в branches.conf (v4.1) | Очистить conf, удалить json, и **вычистить серии**: включить admin API (`ARGS="--web.enable-admin-api"` в `/etc/default/prometheus`, restart), затем `curl -X POST -g 'localhost:9090/api/v1/admin/tsdb/delete_series?match[]={instance=~"10.200.*"}'`, `curl -X POST localhost:9090/api/v1/admin/tsdb/clean_tombstones`, вернуть ARGS="", restart. Результат проверять ТОЛЬКО через `/api/v1/label/instance/values` (instant query уставшие серии не показывает!) |
| `spb.json` с `"targets": [""]` | scanner-branches v4.1 при пустом результате | Исправлено в v4.2 (пустой результат → файл удаляется) |

---

## 8. Роадмап

- [ ] SNMP MikroTik (шаблон «MikroTik by SNMP»)
- [ ] Blackbox-exporter: ping «чужих» устройств, ICMP+HTTPS для VIP
- [ ] Авто-добавление хостов в Zabbix через API (scanner → host.create)
- [ ] Разбор `blikvm_storage_available_bytes = 0` (баг прошивки?)
- [ ] Экспортёр PostgreSQL для HA-пары (репликация, слоты)
