# Linux: структура каталогов и куда что класть

> Основы ОС — [Linux (теория)](linux.md). Команды для работы с файлами — [Linux: команды](linux-commands.md). Что делать, когда диск заполнен, — [Linux: диагностика](linux-troubleshooting.md).

В Linux нет дисков `C:` и `D:` — всё растёт из одного корня `/`, а другие диски и разделы **монтируются** в каталоги этого дерева. Какой каталог для чего нужен, описывает стандарт **FHS** (Filesystem Hierarchy Standard). Его соблюдают все дистрибутивы, пакеты, Docker, systemd — поэтому, зная FHS, ты на любом сервере сразу понимаешь, где конфиг, где данные, где логи, и сам раскладываешь свои приложения так, что их поймут другие.

```bash
man hier               # описание иерархии каталогов
man file-hierarchy     # то же от systemd (современнее)
```

## Карта корня

```
/
├── bin → usr/bin        программы (симлинк в современных дистрибутивах)
├── sbin → usr/sbin      системные программы (симлинк)
├── lib → usr/lib        библиотеки (симлинк)
├── boot                 ядро и загрузчик
├── dev                  устройства (виртуальная ФС)
├── etc                  конфигурация
├── home                 домашние каталоги пользователей
├── root                 домашний каталог root
├── opt                  сторонний софт «одной папкой»
├── srv                  данные, которые отдаёт сервер
├── mnt                  временное монтирование руками
├── media                съёмные носители
├── usr                  программы и библиотеки из пакетов (только чтение)
│   └── local            то же, но установленное вручную
├── var                  изменяемые данные: логи, базы, кеш, очереди
├── tmp                  временные файлы
├── run                  данные запущенных процессов (в памяти)
├── proc                 процессы и ядро (виртуальная ФС)
└── sys                  устройства и драйверы (виртуальная ФС)
```

## Классификация FHS: статичное и изменяемое

FHS делит данные по двум признакам:

| | **Общие** (можно разделить между серверами) | **Локальные** (у каждого сервера свои) |
|---|---|---|
| **Статичные** (меняются только при установке/обновлении) | `/usr`, `/opt` | `/etc`, `/boot` |
| **Изменяемые** (меняются во время работы) | `/var/mail`, `/srv` | `/var/log`, `/var/lib`, `/var/run`, `/tmp` |

Практический смысл:

* **Статичное** можно монтировать только для чтения, восстанавливать переустановкой пакетов, запекать в образ.
* **Изменяемое** нужно **бэкапить** (`/var/lib`), **ротировать** (`/var/log`), **мониторить по месту** (весь `/var`), выносить на отдельный диск.

## Основные системные каталоги

| Каталог | Что там | Кто пишет | Можно ли туда класть своё |
|---|---|---|---|
| `/` | корень всего дерева | — | нет, только каталоги верхнего уровня |
| `/bin`, `/sbin` | команды (`ls`, `cp`, `ip`, `mount`). В современных Ubuntu/Debian/RHEL — **симлинки** на `/usr/bin`, `/usr/sbin` («merged /usr») | пакетный менеджер | нет |
| `/boot` | ядро `vmlinuz-*`, `initrd`, конфиг GRUB | пакеты ядра | нет. Маленький раздел — старые ядра могут его заполнить |
| `/etc` | **конфигурация** системы и сервисов: `nginx/`, `ssh/`, `systemd/`, `fstab`, `hosts`, `passwd` | пакеты + администратор | **да — конфиги своих сервисов** в `/etc/<app>/` |
| `/lib`, `/lib64` | библиотеки и модули ядра (симлинки на `/usr/lib`) | пакеты | нет |
| `/usr` | всё, что установил пакетный менеджер: `/usr/bin`, `/usr/lib`, `/usr/share` (документация, man, данные) | **только пакетный менеджер** | **нет** (кроме `/usr/local`) |
| `/usr/local` | то же дерево (`bin`, `lib`, `share`), но для софта, **установленного вручную** | администратор | **да** — свои бинарники и скрипты в `/usr/local/bin` |
| `/opt` | сторонние приложения «одной папкой»: `/opt/<app>/bin`, `/opt/<app>/lib` | администратор, вендорские пакеты | **да** — своё приложение целиком |
| `/home` | домашние каталоги людей: `/home/alex` | пользователи | для личных файлов, **не для сервисов** |
| `/root` | домашний каталог root | root | нет, это не место для приложений |
| `/srv` | данные, которые **отдаёт** сервер: сайты, FTP, git-репозитории (`/srv/www`, `/srv/git`) | администратор | **да** |
| `/mnt` | временное ручное монтирование (`mount /dev/vdb1 /mnt`) | администратор | только временно |
| `/media` | автоматическое монтирование флешек и дисков | система | нет |

> **Главное правило:** в `/usr` (кроме `/usr/local`), `/bin`, `/lib`, `/boot` руками не пишем. Этим владеет пакетный менеджер. Положишь туда файл — его перезапишет обновление или ты сломаешь пакет.

## Вторичные и изменяемые каталоги

### /var — изменяемые данные

`/var` (variable) — всё, что **растёт и меняется во время работы**. Здесь чаще всего кончается место.

| Каталог | Что там | Особенность |
|---|---|---|
| `/var/log` | **логи**: `syslog`/`messages`, `auth.log`/`secure`, `nginx/`, `journal/` | ротируется (logrotate, journald) |
| `/var/lib` | **состояние приложений**: базы (`postgresql/`, `mysql/`), `docker/`, `containerd/`, `kubelet/`, `apt/`, `dpkg/` | **самое ценное — бэкапить** |
| `/var/cache` | кеш: пакеты apt (`apt/archives`), кеш приложений | можно удалить без потери данных |
| `/var/spool` | очереди на обработку: `cron/`, почта, печать | обрабатываются и удаляются |
| `/var/tmp` | временные файлы, которые **переживают перезагрузку** | чистится редко (systemd-tmpfiles, ~30 дней) |
| `/var/www` | сайты по умолчанию в Debian/Ubuntu (nginx, apache) | исторически; по FHS правильнее `/srv/www` |
| `/var/backups` | небольшие системные бэкапы (Debian: `dpkg`, `passwd`) | не для бэкапов баз — они должны быть **вне сервера** |
| `/var/mail` | почтовые ящики пользователей | |
| `/var/run`, `/var/lock` | **симлинки** на `/run` и `/run/lock` | |

### /tmp и /run

| Каталог | Что там | Переживает перезагрузку |
|---|---|---|
| `/tmp` | временные файлы любых программ, **доступен всем** на запись (sticky bit: удалить можно только свой) | **нет** (часто tmpfs в памяти или очищается при загрузке) |
| `/run` | данные запущенных процессов: **PID-файлы**, **UNIX-сокеты** (`/run/docker.sock`, `/run/postgresql/`), lock-файлы | **нет** — tmpfs в оперативной памяти |
| `/dev/shm` | общая память между процессами | нет, tmpfs |

```bash
ls -ld /tmp
# drwxrwxrwt  — буква t на конце: sticky bit
findmnt /run /tmp /dev/shm        # tmpfs или обычный диск
```

### Виртуальные каталоги: /proc, /sys, /dev

Это не файлы на диске — ядро **генерирует их на лету**. Занимают 0 байт, бэкапить и копировать их нельзя.

| Каталог | Что там | Примеры |
|---|---|---|
| `/proc` | процессы и параметры ядра | `/proc/cpuinfo`, `/proc/meminfo`, `/proc/loadavg`, `/proc/<pid>/` (всё о процессе), `/proc/sys/` (настройки ядра = `sysctl`) |
| `/sys` | устройства, драйверы, cgroups | `/sys/class/net/eth0/`, `/sys/block/vda/`, `/sys/fs/cgroup/` |
| `/dev` | файлы устройств | `/dev/vda`, `/dev/sda`, `/dev/nvme0n1` (диски), `/dev/null`, `/dev/zero`, `/dev/urandom`, `/dev/tty` |

```bash
cat /proc/loadavg                     # load average
cat /proc/sys/net/ipv4/ip_forward     # 1 — включена маршрутизация (нужно для Docker/K8s)
sysctl net.ipv4.ip_forward            # то же через sysctl
ls -l /proc/$(pgrep -o nginx)/cwd     # рабочий каталог процесса
cat /sys/class/net/eth0/address       # MAC-адрес
command > /dev/null 2>&1              # выкинуть вывод
head -c 32 /dev/urandom | base64      # случайная строка
```

Постоянные настройки ядра — не в `/proc/sys` (сбросятся при перезагрузке), а в `/etc/sysctl.d/99-myapp.conf` + `sysctl --system`.

## Куда что деплоить и сохранять

Главная таблица раздела.

| Что | Куда | Пример |
|---|---|---|
| **Своё приложение целиком** (код, зависимости, venv, jar) | `/opt/<app>/` | `/opt/shop/`, `/opt/shop/current/bin/shop` |
| **Один бинарник или скрипт** вручную | `/usr/local/bin/` (`/usr/local/sbin/` — только для root) | `/usr/local/bin/node_exporter`, `/usr/local/bin/backup-db.sh` |
| **Конфигурация** | `/etc/<app>/` | `/etc/shop/config.yaml` |
| **Дополнения к чужому конфигу** | каталоги `*.d/` (drop-in) | `/etc/nginx/conf.d/shop.conf`, `/etc/ssh/sshd_config.d/10-hardening.conf`, `/etc/sysctl.d/`, `/etc/sudoers.d/` |
| **Переменные окружения и секреты сервиса** | `/etc/<app>/` с правами `600` | `/etc/shop/shop.env` → `EnvironmentFile=` в systemd |
| **Данные (состояние)**: базы, загрузки, индексы | `/var/lib/<app>/` | `/var/lib/shop/uploads/` |
| **Логи** (если не journald) | `/var/log/<app>/` + правило logrotate | `/var/log/shop/app.log`, `/etc/logrotate.d/shop` |
| **Кеш** — можно удалить без потерь | `/var/cache/<app>/` | `/var/cache/shop/thumbnails/` |
| **PID-файлы и сокеты** | `/run/<app>/` | `/run/shop/shop.sock` |
| **Временные файлы** | `/tmp` (исчезнут при перезагрузке) или `/var/tmp` (переживут) | |
| **Статика сайта**, которую отдаёт nginx | `/srv/www/<site>/` или `/var/www/<site>/` (Debian) | `/var/www/docs/` |
| **systemd-юниты своих сервисов** | `/etc/systemd/system/` | `/etc/systemd/system/shop.service` |
| **Переопределение чужого юнита** | `/etc/systemd/system/<unit>.d/override.conf` (`systemctl edit <unit>`) | `/etc/systemd/system/nginx.service.d/override.conf` |
| **cron-задачи** | `/etc/cron.d/<app>` (или systemd timer) | `/etc/cron.d/shop-cleanup` |
| **Свой корневой сертификат (CA)** | Debian/Ubuntu: `/usr/local/share/ca-certificates/*.crt` + `update-ca-certificates`; RHEL: `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust` | |
| **TLS-сертификат сайта** | `/etc/ssl/certs/` (публичный), `/etc/ssl/private/` (ключ, права `600`/`640`), Let's Encrypt — `/etc/letsencrypt/live/<domain>/` | |
| **Переменные окружения для всех пользователей** | `/etc/profile.d/<name>.sh` (для shell), `/etc/environment` | `/etc/profile.d/proxy.sh` |
| **Правила sudo** | `/etc/sudoers.d/<name>` — только через `visudo -f` | `/etc/sudoers.d/deploy` |
| **Личные файлы и скрипты** | `/home/<user>/`, `~/bin` или `~/.local/bin` | |

### Где свои файлы хранят известные сервисы

Удобно знать, чтобы понимать, что бэкапить и что может заполнить диск:

| Сервис | Конфиг | Данные | Логи |
|---|---|---|---|
| nginx | `/etc/nginx/` | `/var/www/`, `/var/cache/nginx/` | `/var/log/nginx/` |
| PostgreSQL | `/etc/postgresql/<ver>/main/` (Debian) или в каталоге данных (RHEL) | `/var/lib/postgresql/<ver>/main/` | `/var/log/postgresql/` |
| Docker | `/etc/docker/daemon.json` | `/var/lib/docker/` (образы, тома, контейнеры) | journald; логи контейнеров в `/var/lib/docker/containers/<id>/` |
| containerd | `/etc/containerd/config.toml` | `/var/lib/containerd/` | journald |
| kubelet / Kubernetes | `/etc/kubernetes/` (манифесты control plane, kubeconfig), `/var/lib/kubelet/config.yaml` | `/var/lib/kubelet/`, `/var/lib/etcd/` | `/var/log/pods/`, `/var/log/containers/` |
| Prometheus (пакет) | `/etc/prometheus/` | `/var/lib/prometheus/` | journald |
| cloud-init | `/etc/cloud/` | `/var/lib/cloud/` | `/var/log/cloud-init*.log` |
| systemd journal | `/etc/systemd/journald.conf` | — | `/var/log/journal/` (постоянный) или `/run/log/journal/` (в памяти) |

## Пример: правильный деплой своего сервиса

Разложим приложение `shop` по FHS так, чтобы его было легко обновлять, откатывать, бэкапить и понимать.

```
/opt/shop/
├── releases/
│   ├── 2026-09-28_1402/        # предыдущая версия
│   └── 2026-09-30_1015/        # текущая версия
└── current -> releases/2026-09-30_1015     # симлинк на активную версию
/etc/shop/
├── config.yaml                 # конфиг (644)
└── shop.env                    # секреты и переменные (600, владелец root или shop)
/var/lib/shop/                  # данные — бэкапить
/var/log/shop/                  # логи — ротировать
/var/cache/shop/                # кеш — можно чистить
/run/shop/                      # сокет и PID — создаётся при старте
/etc/systemd/system/shop.service
/etc/logrotate.d/shop
```

### 1. Системный пользователь

Сервис не должен работать от root и не должен иметь пароль и shell:

```bash
sudo useradd --system \
  --home-dir /var/lib/shop \
  --shell /usr/sbin/nologin \
  --user-group shop
```

### 2. Каталоги с правильными правами

```bash
sudo install -d -m 0755 /opt/shop/releases
sudo install -d -m 0755 /etc/shop
sudo install -d -o shop -g shop -m 0750 /var/lib/shop /var/log/shop /var/cache/shop
sudo install -m 0600 -o root -g root shop.env /etc/shop/shop.env
```

> `install -d` создаёт каталог сразу с владельцем и правами — одной командой вместо `mkdir` + `chown` + `chmod`.

### 3. systemd-юнит: пусть systemd создаёт каталоги сам

```ini
# /etc/systemd/system/shop.service
[Unit]
Description=Shop service
After=network-online.target
Wants=network-online.target

[Service]
User=shop
Group=shop
WorkingDirectory=/opt/shop/current
ExecStart=/opt/shop/current/bin/shop --config /etc/shop/config.yaml
EnvironmentFile=/etc/shop/shop.env

# systemd создаст каталоги с владельцем shop перед стартом:
StateDirectory=shop           # /var/lib/shop
LogsDirectory=shop            # /var/log/shop
CacheDirectory=shop           # /var/cache/shop
RuntimeDirectory=shop         # /run/shop (удаляется при остановке)
ConfigurationDirectory=shop   # /etc/shop (только чтение для сервиса)

# ограничения: сервис видит файловую систему только для чтения, кроме своих каталогов
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true               # свой изолированный /tmp
NoNewPrivileges=true

Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now shop
systemctl status shop
```

С `ProtectSystem=strict` сервис **физически не сможет** записать никуда, кроме `StateDirectory`/`LogsDirectory`/`CacheDirectory`/`RuntimeDirectory` — хорошая защита и проверка, что приложение разложено правильно.

### 4. Выкладка новой версии с быстрым откатом

```bash
REL=/opt/shop/releases/$(date +%F_%H%M)
sudo mkdir -p "$REL"
sudo tar -xzf shop-1.4.2.tar.gz -C "$REL"

# атомарно переключить симлинк: сначала новый симлинк рядом, потом mv поверх старого
sudo ln -sfn "$REL" /opt/shop/current.new
sudo mv -T /opt/shop/current.new /opt/shop/current
sudo systemctl restart shop

# откат — переключить симлинк на предыдущий релиз
PREV=$(ls -1d /opt/shop/releases/* | sort | tail -2 | head -1)
sudo ln -sfn "$PREV" /opt/shop/current.new && sudo mv -T /opt/shop/current.new /opt/shop/current
sudo systemctl restart shop

# хранить последние 5 релизов
ls -1d /opt/shop/releases/* | sort | head -n -5 | xargs -r sudo rm -rf
```

> Данные и конфиги **не лежат внутри релиза** — поэтому релизы можно удалять и переключать, ничего не теряя.

### 5. Ротация логов

```
# /etc/logrotate.d/shop
/var/log/shop/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 shop shop
    sharedscripts
    postrotate
        systemctl kill -s HUP shop.service >/dev/null 2>&1 || true
    endscript
}
```

```bash
sudo logrotate -d /etc/logrotate.d/shop     # dry-run: проверить правило
```

Если приложение пишет в stdout — логи сразу уходят в journald (`journalctl -u shop`), и каталог `/var/log/shop` с logrotate не нужен.

## Разделы и точки монтирования

На серверах часто выносят отдельные разделы или диски, чтобы **один заполнившийся каталог не положил всю систему**:

| Точка монтирования | Зачем отдельно | Опции |
|---|---|---|
| `/var` или `/var/log` | логи не заполнят корень → система продолжит работать | |
| `/var/lib/docker`, `/var/lib/containerd` | образы и слои быстро растут; отдельный быстрый диск | |
| `/var/lib/postgresql` (данные БД) | производительность (SSD), размер, снапшоты отдельно от ОС | |
| `/home` | пользователи не заполнят систему | `nodev,nosuid` |
| `/tmp` | безопасность: запретить запуск файлов | `nodev,nosuid,noexec` (или tmpfs) |
| `/boot` | загрузчик; часто отдельный маленький раздел | |

```bash
lsblk -f                 # диски, разделы, файловые системы, точки монтирования
findmnt                  # дерево монтирования
df -hT                   # занятость по разделам с типом ФС
cat /etc/fstab           # что монтируется при загрузке
```

```
# /etc/fstab — подключить диск данных по UUID (не по /dev/vdb — имя может смениться)
UUID=3f1a...-...  /var/lib/shop  ext4  defaults,noatime,nofail  0  2
```

> `nofail` — если диск не подключился, сервер всё равно загрузится (иначе застрянет в emergency mode). После правки `fstab` — `sudo mount -a` и `findmnt --verify`, **до** перезагрузки.

## Внутри контейнеров

В Docker-образах та же структура FHS, но правила другие:

* **Корень контейнера — временный.** Всё, что записано не в том, исчезнет при пересоздании контейнера.
* Данные — только в **тома**, смонтированные в каталог данных: `/var/lib/postgresql/data`, `/data`, `/var/lib/<app>`.
* Логи — в **stdout/stderr**, а не в `/var/log` внутри контейнера.
* Конфиги — через ConfigMap/volume в `/etc/<app>/`.
* При `readOnlyRootFilesystem: true` в Kubernetes писать можно только в смонтированные тома — для `/tmp` монтируют `emptyDir`.

```yaml
# Kubernetes: корень только для чтения, /tmp и данные — отдельными томами
securityContext:
  readOnlyRootFilesystem: true
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: data
    mountPath: /var/lib/shop
volumes:
  - name: tmp
    emptyDir: {}
  - name: data
    persistentVolumeClaim:
      claimName: shop-data
```

## Полезные команды

```bash
dpkg -S /usr/bin/curl            # какой пакет установил файл (Debian/Ubuntu)
rpm -qf /usr/bin/curl            # то же в RHEL
dpkg -L nginx                    # какие файлы поставил пакет
rpm -ql nginx
ls -l /bin /sbin /lib            # симлинки на /usr/* → «merged /usr»
systemd-path                     # стандартные пути systemd
du -xh --max-depth=1 /var | sort -rh | head    # что занимает место в /var
stat /etc/shop/shop.env          # права, владелец, даты
namei -l /opt/shop/current/bin/shop   # права на каждый каталог пути (почему «Permission denied»)
```

## Частые ошибки

| Ошибка | Чем плохо | Как правильно |
|---|---|---|
| Приложение в `/root/app` или `/home/user/app` | сервис зависит от чужого домашнего каталога; `ProtectHome` сломает его; права путаются | `/opt/<app>` + системный пользователь |
| Свой бинарник в `/usr/bin` | перезапишется пакетом или сломает пакет, непонятно, откуда взялся | `/usr/local/bin` |
| Важные данные в `/tmp` | удалятся при перезагрузке или очистке | `/var/lib/<app>` |
| Данные и конфиг внутри каталога релиза | при обновлении/откате пропадают | данные — `/var/lib`, конфиг — `/etc` |
| Правка файла пакета в `/etc/nginx/nginx.conf` вместо drop-in | конфликт при обновлении пакета | свои файлы в `conf.d/`, `*.d/`, `systemctl edit` |
| Логи без ротации | `/var` заполняется, сервисы падают | logrotate или journald |
| Всё на одном разделе с корнем | логи/Docker заполнили диск → не работает SSH и systemd | отдельные разделы/диски для `/var`, `/var/lib/docker`, данных БД |
| Диск в `fstab` по `/dev/vdb` без `nofail` | после перезагрузки имя сменилось или диск не подключился — сервер не грузится | `UUID=` + `nofail`, проверка `findmnt --verify` |
| Секреты в `/etc/<app>/` с правами `644` | читает любой пользователь сервера | `600` / `640`, владелец — root или пользователь сервиса |
| Настройки ядра записаны в `/proc/sys` | пропадут после перезагрузки | `/etc/sysctl.d/*.conf` |

## Best Practices

* **Раскладка по FHS**: код — `/opt`, конфиги — `/etc`, данные — `/var/lib`, логи — `/var/log`, runtime — `/run`.
* **Не трогай то, что принадлежит пакетному менеджеру** — дополняй через `*.d/` и `/usr/local`.
* **Системный пользователь** для каждого сервиса, без shell и пароля.
* **Каталоги через systemd** (`StateDirectory=` и др.) + `ProtectSystem=strict`.
* **Релизы с симлинком `current`** — атомарное переключение и быстрый откат.
* **Бэкапь `/etc` и `/var/lib`**, остальное восстанавливается переустановкой.
* **Отдельные диски для растущих данных**, мониторинг места и inodes на каждом разделе.
* **Всё это — через Ansible или образ**, а не руками на каждом сервере.
