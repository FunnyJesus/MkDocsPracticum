# cloud-init: первичная настройка виртуальных машин

> Облака в целом — [Облака](cloud.md). Создание VM кодом — [IaC](iac.md), [Terraform продвинутый](terraform-advanced.md). Дальнейшая настройка — [Ansible](ansible.md).

**cloud-init** — стандартный инструмент, который настраивает виртуальную машину **при первой загрузке**: создаёт пользователей, кладёт SSH-ключи, ставит пакеты, пишет файлы, запускает команды. Он встроен почти во все облачные образы Linux (Ubuntu, Debian, RHEL/Rocky/Alma, Amazon Linux) и работает во всех облаках: AWS, GCP, Azure, Yandex Cloud, VK Cloud, OpenStack, а также в Proxmox, Multipass, LXD.

## Зачем

Без cloud-init новая VM — «голая»: зайти можно только с ключом, заданным при создании, всё остальное — руками. С cloud-init VM при первом старте сама:

* создаёт пользователя `deploy` с твоим ключом и sudo;
* закрывает вход по паролю и под root;
* ставит Docker, node_exporter, агенты;
* пишет конфиги и запускает сервисы;
* сообщает, что готова.

| | cloud-init | Ansible | Образ (Packer) |
|---|---|---|---|
| Когда работает | один раз при первой загрузке | когда запустишь, сколько угодно раз | заранее, при сборке образа |
| Откуда | внутри VM | снаружи по SSH | — |
| Для чего | базовая подготовка: пользователи, ключи, пакеты, «доступ для Ansible» | полноценная и повторяемая настройка | всё тяжёлое и неизменное «запечь» заранее |

> Типичная связка: **Terraform** создаёт VM и передаёт **cloud-init**, cloud-init делает минимум (пользователь, ключ, hardening SSH, Python), дальше **Ansible** настраивает остальное. Или: **Packer** собирает образ со всем софтом, а cloud-init только подставляет то, что отличается у каждой VM.

## Как это работает

```
Terraform / консоль облака
        │ user-data (твой YAML)
        ▼
Metadata service облака  (http://169.254.169.254/...)   ← datasource
        │
        ▼
VM загружается → cloud-init читает метаданные и user-data → выполняет по стадиям
```

Что cloud-init получает из **datasource** (источника данных):

| Данные | Что это | Кто задаёт |
|---|---|---|
| **meta-data** | instance-id, hostname, регион, SSH-ключ из консоли | облако |
| **user-data** | твоя конфигурация (`#cloud-config` или скрипт) | ты |
| **vendor-data** | настройки от провайдера облака | облако |
| **network-config** | настройка сети | облако (обычно) |

Datasource-ы: EC2 (AWS), GCE (GCP, Yandex), Azure, OpenStack, **NoCloud** (файлы на диске или ISO — для локальных тестов и Proxmox), ConfigDrive и др.

### Стадии загрузки

| Стадия | systemd-юнит (зависит от версии) | Что происходит |
|---|---|---|
| **Detect** | `ds-identify` | определить, в каком облаке запущены |
| **Local** | `cloud-init-local.service` | до сети: найти datasource, применить сетевую конфигурацию |
| **Network** | `cloud-init.service` (в новых версиях `cloud-init-network.service`) | сеть есть: получить user-data, `bootcmd`, `write_files`, диски, пользователи, SSH |
| **Config** | `cloud-config.service` | модули конфигурации: apt, NTP, timezone и др. |
| **Final** | `cloud-final.service` | в самом конце: `packages`, `runcmd`, скрипты, `final_message` |

```bash
systemctl list-units 'cloud*'     # точные имена юнитов в твоей версии
```

### «Только один раз»

cloud-init запоминает **instance-id**. При обычной перезагрузке большинство модулей **не выполняется повторно** — только если instance-id сменился (новая VM, в том числе из снапшота) или состояние очищено вручную.

| Частота модуля | Когда выполняется | Примеры |
|---|---|---|
| `once-per-instance` | один раз на VM (по умолчанию) | `users`, `packages`, `runcmd`, `write_files` |
| `always` | при каждой загрузке | `bootcmd` |
| `once` | один раз вообще, даже для новых instance-id | редко |

> Поэтому **поменять user-data у уже работающей VM и перезагрузить её — недостаточно**: cloud-init не применит изменения. Нужно пересоздать VM или очистить состояние (см. «Перезапуск» ниже).

## Форматы user-data

Формат определяется **первой строкой**:

| Первая строка | Формат |
|---|---|
| `#cloud-config` | YAML-конфигурация (основной вариант) |
| `#!/bin/bash` | обычный скрипт, выполнится один раз на стадии Final |
| `## template: jinja` + `#cloud-config` на второй строке | YAML с подстановками из метаданных (`{{ v1.local_hostname }}`) |
| `Content-Type: multipart/mixed` | несколько частей сразу (конфиг + скрипт) |
| `#include` | список URL, откуда скачать user-data |

!!! warning "Самая частая ошибка"
    Первая строка должна быть **ровно** `#cloud-config` — без пробела после `#`, без BOM, без пустой строки перед ней. Иначе cloud-init не распознает YAML и молча его проигнорирует.

## Конфигурация #cloud-config

### Базовая подготовка сервера

```yaml
#cloud-config

# --- имя и время ---
hostname: web-1
fqdn: web-1.example.internal
prefer_fqdn_over_hostname: false
timezone: Europe/Moscow

# --- пользователи ---
users:
  - default                          # оставить пользователя образа (ubuntu, ec2-user…)
  - name: deploy
    gecos: Deploy user
    groups: [sudo, docker]           # группы должны существовать (docker создастся позже — см. ниже)
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true                # вход по паролю запрещён
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... alex@laptop

# --- SSH ---
ssh_pwauth: false                    # PasswordAuthentication no
disable_root: true                   # запретить вход под root
ssh_deletekeys: true                 # новые host-ключи для каждой VM

# --- пакеты ---
package_update: true                 # apt update
package_upgrade: true                # apt upgrade (замедляет первый старт)
package_reboot_if_required: true     # перезагрузиться, если обновилось ядро
packages:
  - curl
  - htop
  - jq
  - fail2ban
  - python3                          # для Ansible

# --- файлы ---
write_files:
  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      MaxAuthTries 3

  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      maxretry = 5
      bantime = 1h

  - path: /home/deploy/.bashrc.d/aliases.sh
    owner: deploy:deploy
    permissions: "0644"
    defer: true                      # записать в конце (Final), когда пользователь deploy уже существует
    content: |
      alias k=kubectl

# --- команды (один раз, в самом конце) ---
runcmd:
  - systemctl restart ssh
  - systemctl enable --now fail2ban
  - [sh, -c, "echo 'provisioned at $(date -Is)' > /var/log/provisioned"]

final_message: "cloud-init finished in $UPTIME seconds"
```

### Модули, которые нужны чаще всего

| Ключ | Что делает | Стадия |
|---|---|---|
| `bootcmd` | команды при **каждой** загрузке, очень рано (до сети и пакетов) | Network |
| `write_files` | создать файлы; `defer: true` — в конце, после пакетов и пользователей | Network / Final |
| `users`, `groups` | пользователи и группы | Network |
| `ssh_authorized_keys`, `ssh_pwauth`, `disable_root` | SSH | Network |
| `mounts`, `disk_setup`, `fs_setup` | разметить и смонтировать диски | Network |
| `growpart`, `resize_rootfs` | растянуть корневой раздел на весь диск (включены по умолчанию) | Network |
| `swap` | создать swap-файл | Network |
| `apt`, `yum_repos` | свои репозитории и ключи | Config |
| `ntp`, `timezone`, `locale` | время и локаль | Config |
| `package_update`, `packages` | установка пакетов | Final |
| `runcmd` | команды **один раз**, в самом конце | Final |
| `ansible` | запустить `ansible-pull` из git | Final |
| `phone_home` | отправить POST на URL, когда всё готово | Final |
| `power_state` | перезагрузить/выключить после завершения | Final |

### runcmd vs bootcmd vs скрипт

| | `bootcmd` | `runcmd` | `#!/bin/bash` user-data |
|---|---|---|---|
| Когда | каждая загрузка, рано | один раз, в конце | один раз, в конце |
| Сеть и пакеты уже есть | нет | да | да |
| Для чего | то, что должно происходить до всего остального (настройка диска, модули ядра) | основной сценарий: включить сервисы, скачать и запустить | если нужен только скрипт без YAML |

Элементы `runcmd`: строка выполняется через `sh -c`; список (`[cmd, arg1, arg2]`) — напрямую без shell. Скрипт из `runcmd` сохраняется в `/var/lib/cloud/instance/scripts/runcmd` — удобно смотреть при отладке.

### Пример: Docker + node_exporter

```yaml
#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl

groups:
  - docker                           # создать группу заранее, чтобы users мог её назначить

users:
  - default
  - name: deploy
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... alex@laptop

write_files:
  - path: /etc/systemd/system/node_exporter.service
    content: |
      [Unit]
      Description=Prometheus node_exporter
      After=network-online.target

      [Service]
      User=nobody
      ExecStart=/usr/local/bin/node_exporter
      Restart=always

      [Install]
      WantedBy=multi-user.target

runcmd:
  # Docker из официального скрипта (для учебного стенда; в проде — репозиторий apt)
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  # node_exporter
  - |
    set -e
    VER=1.8.2
    curl -fsSL -o /tmp/ne.tgz https://github.com/prometheus/node_exporter/releases/download/v${VER}/node_exporter-${VER}.linux-amd64.tar.gz
    tar -xzf /tmp/ne.tgz -C /tmp
    install -m 0755 /tmp/node_exporter-${VER}.linux-amd64/node_exporter /usr/local/bin/node_exporter
  - systemctl daemon-reload
  - systemctl enable --now node_exporter
```

### Пример: передать настройку в Ansible (ansible-pull)

```yaml
#cloud-config
ansible:
  install_method: distro             # поставить ansible из пакетов дистрибутива
  pull:
    url: https://github.com/company/infra-ansible.git
    playbook_name: site.yml
```

## Передача user-data

### Terraform: Yandex Cloud

```hcl
resource "yandex_compute_instance" "web" {
  name = "web-1"
  # ...
  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      ssh_key = file("~/.ssh/id_ed25519.pub")
    })
  }
}
```

```yaml
#cloud-config
# cloud-init.yaml.tftpl — ${...} подставит Terraform
users:
  - name: deploy
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_key}
```

> В шаблоне `templatefile` конструкция `${...}` принадлежит Terraform. Если в скрипте нужен shell-овый `${VAR}`, пиши `$${VAR}`.

### Terraform: AWS

```hcl
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_key = file("~/.ssh/id_ed25519.pub")
  })
  user_data_replace_on_change = true   # поменял user-data → VM пересоздастся (иначе изменения не применятся)
}
```

### Несколько частей: провайдер cloudinit

```hcl
data "cloudinit_config" "web" {
  gzip          = true               # AWS: лимит user-data 16 КБ, gzip помогает
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = file("${path.module}/base.yaml")
  }
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/bootstrap.sh")
  }
}

resource "aws_instance" "web" {
  # ...
  user_data_base64 = data.cloudinit_config.web.rendered
}
```

### Консоль облака и CLI

```bash
# Yandex Cloud
yc compute instance create --name web-1 ... --metadata-from-file user-data=cloud-init.yaml

# AWS
aws ec2 run-instances --image-id ami-... --instance-type t3.micro --user-data file://cloud-init.yaml
```

## Проверка работы cloud-init

Проверять нужно на **трёх этапах**: конфиг до запуска, прогон локально, результат на реальной VM.

### 1. До запуска: валидация конфига

```bash
# встроенная проверка схемы (cloud-init есть на любой Ubuntu, можно поставить: apt install cloud-init)
cloud-init schema --config-file cloud-init.yaml --annotate
# Valid schema cloud-init.yaml          ← всё хорошо
# или ошибки с номерами строк:
# 12: users.0.sudo: ... is not valid under any of the given schemas

# в старых версиях команда называлась:
cloud-init devel schema --config-file cloud-init.yaml

# отдельно синтаксис YAML (быстро, без cloud-init)
yamllint cloud-init.yaml
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' cloud-init.yaml

# первая строка ровно "#cloud-config"
head -1 cloud-init.yaml | cat -A      # ожидаем: #cloud-config$   (без ^M и пробелов)
```

Эту проверку стоит поставить в **CI** и **pre-commit** репозитория с Terraform:

```yaml
# фрагмент .gitlab-ci.yml
validate-cloud-init:
  image: ubuntu:24.04
  script:
    - apt-get update -qq && apt-get install -y -qq cloud-init > /dev/null
    - for f in cloud-init/*.yaml; do cloud-init schema --config-file "$f" --annotate; done
```

> Если файл — шаблон Terraform (`.tftpl`), сначала отрендери его (`terraform console` / `templatefile` в тестовом output) и валидируй результат.

### 2. Локальный прогон без облака

Самый быстрый способ увидеть, что конфиг реально работает, — поднять локальную VM с тем же user-data.

**Multipass** (Ubuntu VM на ноутбуке, macOS/Linux/Windows):

```bash
brew install --cask multipass
multipass launch 24.04 --name ci-test --cloud-init cloud-init.yaml
multipass exec ci-test -- cloud-init status --wait --long
multipass exec ci-test -- sudo cat /var/log/cloud-init-output.log
multipass shell ci-test
multipass delete --purge ci-test
```

**LXD** (контейнер или VM на Linux):

```bash
lxc launch ubuntu:24.04 ci-test --config=user.user-data="$(cat cloud-init.yaml)"
lxc exec ci-test -- cloud-init status --wait --long
lxc delete --force ci-test
```

**QEMU / Proxmox — datasource NoCloud** (ISO с user-data):

```bash
# meta-data
cat > meta-data <<EOF
instance-id: test-001
local-hostname: ci-test
EOF

cloud-localds seed.img cloud-init.yaml meta-data     # пакет cloud-image-utils
# подключить seed.img к VM как второй диск/CD-ROM — cloud-init найдёт его сам
```

### 3. На VM: дождаться и проверить статус

```bash
cloud-init status                # status: running / done / error / disabled
cloud-init status --wait         # ждать завершения (удобно в скриптах)
cloud-init status --long         # подробности: стадия, datasource, текст ошибок
cloud-init status --format json  # для автоматической проверки
```

Коды выхода `cloud-init status --wait`:

| Код | Значение |
|---|---|
| `0` | всё выполнено успешно |
| `1` | критическая ошибка — что-то не выполнилось |
| `2` | завершилось, но с некритичными ошибками/предупреждениями (в новых версиях) |

```bash
# пример вывода --long при ошибке
status: error
extended_status: error - done
boot_status_code: enabled-by-generator
last_update: Mon, 29 Sep 2026 10:12:44 +0000
detail: DataSourceEc2Local
errors:
    - ('scripts_user', RuntimeError('Runparts: 1 failures (runcmd) in 1 attempted commands'))
recoverable_errors: {}
```

### 4. Логи: где искать причину

| Файл / команда | Что там |
|---|---|
| `/var/log/cloud-init-output.log` | **вывод всех команд** (`runcmd`, установка пакетов, скрипты) — начинать отсюда |
| `/var/log/cloud-init.log` | подробный лог самого cloud-init: какие модули, в каком порядке, с какой ошибкой |
| `/run/cloud-init/result.json` | итог: список ошибок и datasource |
| `/run/cloud-init/status.json` | статус по стадиям, время начала/окончания |
| `journalctl -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final` | логи systemd-юнитов (имена — `systemctl list-units 'cloud*'`) |
| `/var/lib/cloud/instance/user-data.txt` | **user-data, который VM реально получила** |
| `/var/lib/cloud/instance/scripts/runcmd` | во что превратился твой `runcmd` |
| `/var/lib/cloud/instance/boot-finished` | файл появляется, когда cloud-init закончил |
| `/var/lib/cloud/instance/sem/` | «семафоры»: какие модули уже выполнены для этой VM |

```bash
sudo grep -iE "error|warn|fail|traceback" /var/log/cloud-init.log
sudo tail -50 /var/log/cloud-init-output.log
sudo cat /run/cloud-init/result.json
ls /var/lib/cloud/instance/sem/        # config_users_groups, config_runcmd… — что уже отработало
```

### 5. Что именно получила VM

Частая причина «не работает» — VM получила не тот user-data (не отрендерился шаблон, обрезался, не та переменная Terraform).

```bash
sudo cloud-init query userdata                 # user-data, который видит cloud-init
sudo cloud-init query --all | jq '.v1'         # все метаданные: облако, регион, instance-id, hostname
cloud-init query v1.instance_id
cloud-init query v1.cloud_name

# проверить схему именно того конфига, который пришёл на эту VM
sudo cloud-init schema --system --annotate
```

Прямо из metadata service облака:

```bash
# AWS (IMDSv2 — с токеном)
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/user-data

# Yandex Cloud / GCP
curl -s -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/attributes/user-data
```

> Любой процесс на VM может прочитать user-data через metadata service. Поэтому **секретов в user-data быть не должно** (см. «Частые ошибки»).

### 6. Сколько заняла каждая стадия

```bash
cloud-init analyze show          # стадии и модули по порядку со временем
cloud-init analyze blame         # самые медленные модули сверху
cloud-init analyze boot          # время загрузки ядра и cloud-init
```

```
-- Boot Record 01 --
     58.21400s (modules-final/config-package-update-upgrade-install)
     12.10300s (modules-final/config-scripts-user)
      1.50200s (init-network/config-ssh)
```

Если первый старт идёт несколько минут — обычно виноват `package_upgrade: true`. Для ускорения тяжёлое переносят в образ (Packer).

### 7. Проверить результат, а не только статус

`status: done` значит «cloud-init отработал», а не «сервер настроен правильно». Проверяй сам результат:

```bash
# пользователь и права
id deploy
sudo -l -U deploy
sudo cat /home/deploy/.ssh/authorized_keys

# SSH-настройки реально применились
sudo sshd -T | grep -Ei "permitrootlogin|passwordauthentication"

# пакеты и сервисы
dpkg -l | grep -E "fail2ban|docker"          # RHEL: rpm -q fail2ban
systemctl is-active fail2ban docker node_exporter
curl -s localhost:9100/metrics | head -3

# файлы
ls -l /etc/ssh/sshd_config.d/10-hardening.conf
hostnamectl
timedatectl | grep "Time zone"
```

Эти проверки удобно собрать в скрипт и запускать после каждого создания VM:

```bash
#!/usr/bin/env bash
# verify-vm.sh <host> — проверить, что cloud-init отработал и сервер настроен
set -euo pipefail
HOST="$1"

ssh -o StrictHostKeyChecking=accept-new "deploy@${HOST}" bash -s <<'EOF'
set -euo pipefail
cloud-init status --wait > /dev/null || { echo "cloud-init: ERROR"; sudo cloud-init status --long; exit 1; }
echo "cloud-init: OK"

sudo sshd -T | grep -q "^passwordauthentication no" && echo "ssh password auth: disabled"
sudo sshd -T | grep -q "^permitrootlogin no"        && echo "ssh root login: disabled"
systemctl is-active --quiet fail2ban                && echo "fail2ban: active"
test -f /var/log/provisioned                        && echo "runcmd: done"
EOF
```

### 8. Автоматическая проверка в Terraform / CI

Дождаться окончания cloud-init прямо в Terraform — чтобы следующий шаг (Ansible, деплой) не начался раньше времени:

```hcl
resource "terraform_data" "wait_cloud_init" {
  triggers_replace = [yandex_compute_instance.web.id]

  connection {
    type        = "ssh"
    host        = yandex_compute_instance.web.network_interface[0].nat_ip_address
    user        = "deploy"
    private_key = file("~/.ssh/id_ed25519")
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || (sudo cloud-init status --long; exit 1)",
    ]
  }
}
```

В Ansible — первой задачей плейбука:

```yaml
- name: Дождаться окончания cloud-init
  ansible.builtin.command: cloud-init status --wait
  changed_when: false
```

> Без этого Ansible часто падает с `Could not get lock /var/lib/dpkg/lock-frontend` — apt ещё занят cloud-init-ом.

`phone_home` — VM сама сообщает о готовности (например, в свой webhook или CI):

```yaml
phone_home:
  url: https://hooks.example.com/vm-ready/$INSTANCE_ID
  post: [instance_id, hostname, fqdn]
  tries: 5
```

### 9. SSH недоступен: консоль VM

Если cloud-init сломал SSH (не тот ключ, опечатка в пользователе), логи можно достать через **серийную консоль** облака:

```bash
# Yandex Cloud
yc compute instance get-serial-port-output --name web-1 | grep -i cloud-init

# AWS
aws ec2 get-console-output --instance-id i-0123456789 --latest --output text | grep -i cloud-init
```

cloud-init пишет в консоль ключевые сообщения, в том числе `final_message` и отпечатки SSH-ключей.

## Перезапуск cloud-init при отладке

На тестовой VM можно не пересоздавать её каждый раз:

```bash
# полностью «как новая VM»: очистить состояние и логи, перезагрузить
sudo cloud-init clean --logs --reboot

# выполнить один модуль заново (без перезагрузки)
sudo cloud-init single --name write_files --frequency always
sudo cloud-init single --name runcmd --frequency always     # пересоздаст скрипт runcmd
sudo /var/lib/cloud/instance/scripts/runcmd                 # и запустить его

# user-data для повторного прогона берётся из datasource — сначала обнови его в облаке
```

> `cloud-init clean` на **боевой** VM приведёт к повторному выполнению всего при следующей загрузке (новые host-ключи SSH, повторный `runcmd`). Используй только на тестовых машинах или при подготовке образа (Packer вызывает `cloud-init clean` в конце сборки, чтобы образ был «чистым»).

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Ничего не применилось, ошибок нет | первая строка не `#cloud-config` (пробел, BOM, `\r\n`) | `head -1 file | cat -A`, сохранить в UTF-8 без BOM и с LF |
| `status: error`, в выводе `Runparts: 1 failures (runcmd)` | команда в `runcmd` вернула ненулевой код | `/var/log/cloud-init-output.log` — вывод команды; `/var/lib/cloud/instance/scripts/runcmd` |
| Поменял user-data, перезагрузил — изменений нет | модули выполняются один раз на instance-id | пересоздать VM (`user_data_replace_on_change`), на тесте — `cloud-init clean --reboot` |
| `write_files` с `owner: deploy` падает | файлы пишутся раньше, чем создаются пользователи | `defer: true` |
| Пользователь не добавлен в группу `docker` | группы ещё нет на момент создания пользователя | создать в `groups:` заранее или `usermod -aG docker deploy` в `runcmd` |
| Не могу войти по SSH после старта | опечатка в ключе, `users:` без `- default` убрал пользователя образа, `lock_passwd` + нет ключа | серийная консоль, `cloud-init schema`, проверить ключ; оставить `- default` при отладке |
| Ansible: `Could not get lock /var/lib/dpkg/lock-frontend` | cloud-init ещё ставит пакеты | `cloud-init status --wait` перед Ansible |
| `Invalid cloud-config`, ключ проигнорирован | опечатка в имени модуля / неверный тип (строка вместо списка) | `cloud-init schema --annotate` |
| YAML не разбирается | табы вместо пробелов, неэкранированный `:` в строке | `yamllint`, брать значения с `:` в кавычки |
| AWS: `User data is limited to 16384 bytes` | большой user-data | gzip (`cloudinit_config`), тяжёлое — в образ или скачивать из S3 |
| Пароль/токен утёк | секрет в user-data, его читает любой процесс через metadata service | секреты не в user-data: Vault, облачный Secret Manager, IAM-роль VM |

## Best Practices

* **cloud-init — только первичная подготовка**: пользователь, ключи, SSH-hardening, агенты. Остальное — Ansible или образ.
* **`cloud-init schema --annotate` в CI** для всех файлов user-data.
* **Проверяй локально в Multipass/LXD**, прежде чем отдавать конфиг в Terraform.
* **Всегда дожидайся `cloud-init status --wait`** перед Ansible и деплоем.
* **Проверяй результат, а не только статус** — скрипт проверки после создания VM.
* **Никаких секретов в user-data.**
* **`user_data_replace_on_change = true`** (или аналог) — изменения user-data не применяются к существующим VM.
* **Тяжёлое — в образ (Packer)**: быстрее старт, меньше зависимостей от сети при загрузке.
* **Храни user-data в git** рядом с Terraform-кодом.
