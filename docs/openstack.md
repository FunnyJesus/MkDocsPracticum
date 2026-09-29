# OpenStack: работа через UI (Horizon) и CLI

> Шпаргалка — [OpenStack: шпаргалка](openstack-cheatsheet.md). Облака в целом — [Облака](cloud.md). Первичная настройка VM — [cloud-init](cloud-init.md). Инфраструктура кодом — [IaC](iac.md).

**OpenStack** — open-source платформа для построения своего облака (IaaS): виртуальные машины, сети, диски, балансировщики, объектное хранилище. На нём работают частные облака компаний и многие публичные облака (VK Cloud, Selectel, OVHcloud и др.). У провайдера интерфейс может быть «перекрашен», но API и CLI — те же самые.

## Сервисы OpenStack

Каждая функция — отдельный сервис со своим API и кодовым именем. Знать имена нужно: они встречаются в ошибках, логах и документации.

| Сервис | Кодовое имя | Что делает | Аналог в AWS |
|---|---|---|---|
| Identity | **Keystone** | аутентификация, проекты, пользователи, роли, каталог API | IAM |
| Compute | **Nova** | виртуальные машины | EC2 |
| Networking | **Neutron** | сети, подсети, роутеры, floating IP, security groups | VPC |
| Block Storage | **Cinder** | диски (volumes) и их снапшоты | EBS |
| Image | **Glance** | образы ОС | AMI |
| Object Storage | **Swift** (или Ceph RGW) | объектное хранилище | S3 |
| Load Balancer | **Octavia** | балансировщики нагрузки | ELB |
| Orchestration | **Heat** | шаблоны инфраструктуры | CloudFormation |
| Dashboard | **Horizon** | веб-интерфейс | Console |
| DNS | **Designate** | DNS-зоны и записи | Route 53 |
| Key Manager | **Barbican** | секреты и сертификаты | KMS / Secrets Manager |
| Containers | **Magnum** | Kubernetes-кластеры | EKS |

## Основные понятия

| Понятие | Что это |
|---|---|
| **Domain** | верхний уровень: группа проектов и пользователей (часто `Default`) |
| **Project** (раньше **tenant**) | «папка» ресурсов со своими квотами и правами. Всё создаётся внутри проекта |
| **Region** | отдельная площадка облака (свои эндпоинты API) |
| **Availability Zone** | часть региона с независимым железом/питанием |
| **Flavor** | «размер» VM: vCPU, RAM, диск (`m1.small`, `standard.2-4`) |
| **Image** | образ ОС в Glance (`Ubuntu 24.04`, `Rocky 9`) |
| **Instance / Server** | виртуальная машина |
| **Key pair** | публичный SSH-ключ, который попадёт в VM |
| **Network / Subnet** | виртуальная сеть и диапазон адресов в ней |
| **Router** | связывает подсети между собой и с внешней сетью |
| **External network** | сеть провайдера (`public`, `ext-net`) — выход в интернет |
| **Floating IP** | публичный адрес из внешней сети, привязывается к VM (NAT 1:1) |
| **Port** | «сетевая карта» VM в подсети: IP, MAC, security groups |
| **Security group** | firewall на уровне порта VM, правила «что разрешено» |
| **Volume** | диск Cinder, живёт отдельно от VM, можно переподключить |
| **Quota** | лимиты проекта: число VM, vCPU, RAM, floating IP, дисков |

### Как устроена сеть

```
                     интернет
                        │
            ┌───────────┴───────────┐
            │  external network     │  (public / ext-net — выдаёт провайдер)
            └───────────┬───────────┘
                        │ gateway
                  ┌─────┴─────┐
                  │  router   │
                  └─────┬─────┘
                        │ interface 10.10.0.1
        ┌───────────────┴────────────────┐
        │  network app-net               │
        │  subnet  10.10.0.0/24          │
        │   ├─ port 10.10.0.11 → web-1 ◄─┼── floating IP 203.0.113.25
        │   └─ port 10.10.0.12 → web-2   │
        └────────────────────────────────┘
```

Чтобы VM была доступна из интернета, нужны **все** звенья: подсеть → роутер с внешним шлюзом → floating IP на порту VM → разрешающее правило в security group.

> Во многих публичных облаках на базе OpenStack есть готовая сеть с доступом в интернет — тогда роутер создавать не нужно. Уточняй в документации провайдера.

## Horizon: веб-интерфейс

### Вход

Адрес выдаёт администратор или провайдер (например `https://dashboard.example.com`). Поля: **Domain** (если облако с несколькими доменами, часто `Default`), **User Name**, **Password**. После входа сверху слева — **выбор проекта** и региона: ресурсы показываются только для выбранного проекта.

### Карта меню

| Раздел | Что там |
|---|---|
| **Project → Compute → Overview** | использование квот проекта — смотреть первым, если «не создаётся» |
| **Compute → Instances** | виртуальные машины и действия над ними |
| **Compute → Images** | образы; можно загрузить свой |
| **Compute → Key Pairs** | SSH-ключи: создать или импортировать публичный |
| **Compute → Server Groups** | группы affinity / anti-affinity |
| **Volumes → Volumes / Snapshots** | диски и снапшоты |
| **Network → Network Topology** | **схема сети** — лучший способ понять, что к чему подключено |
| **Network → Networks / Routers** | сети, подсети, роутеры |
| **Network → Security Groups** | правила firewall |
| **Network → Floating IPs** | публичные адреса |
| **Network → Load Balancers** | Octavia |
| **Object Store → Containers** | объектное хранилище |
| **Orchestration → Stacks** | шаблоны Heat |
| **Project → API Access** | эндпоинты API и **скачивание RC-файла / clouds.yaml** для CLI |
| **Identity** | проекты, пользователи (обычному пользователю — только просмотр) |
| **Admin** | только для администраторов облака |

### Создать VM: мастер Launch Instance

**Compute → Instances → Launch Instance**. Шаги мастера (обязательные отмечены `*`):

| Шаг | Что указать |
|---|---|
| **Details** * | имя, availability zone, количество |
| **Source** * | загрузка из: Image / Volume / Snapshot. **Create New Volume: Yes** — корневой диск будет volume-ом (переживёт удаление VM, если снять «Delete Volume on Instance Delete») |
| **Flavor** * | размер VM; серым показаны flavor-ы, которые не влезают в квоту или меньше требований образа |
| **Networks** * | сеть (или несколько) — стрелкой вверх перенести в Allocated |
| **Network Ports** | заранее созданный порт с фиксированным IP (необязательно) |
| **Security Groups** | группы правил; `default` разрешает только исходящий трафик и трафик внутри группы |
| **Key Pair** | SSH-ключ — **без него по SSH не войти** в большинство облачных образов |
| **Configuration** | **Customization Script** — сюда вставляется [cloud-init](cloud-init.md) (`#cloud-config` …); **Configuration Drive** — передать метаданные диском |
| **Server Groups** | anti-affinity — разнести VM по разным хостам |
| **Metadata** | произвольные метаданные |

**Launch Instance** → статус `Build` → `Active`, power state `Running`.

### Дать доступ из интернета

1. **Network → Security Groups → Create Security Group** → **Manage Rules → Add Rule**: `SSH` (Remote: CIDR своего IP, например `203.0.113.10/32`), `ALL ICMP`, `HTTP`/`HTTPS` при необходимости.
2. **Instances → меню действий VM → Edit Security Groups** — добавить группу.
3. **Instances → Associate Floating IP** → «+» (выделить адрес из внешней сети) → Associate.
4. `ssh -i ~/.ssh/key ubuntu@<floating-ip>` — пользователь зависит от образа (см. «Частые ошибки»).

### Действия с VM

Меню справа от VM в списке **Instances**:

| Действие | Что делает |
|---|---|
| Associate / Disassociate Floating IP | привязать / отвязать публичный адрес |
| Attach / Detach Volume | подключить / отключить диск |
| Attach / Detach Interface | добавить сетевой интерфейс |
| Edit Security Groups | изменить firewall |
| **Console** | VNC-консоль в браузере — если SSH не работает |
| **View Log** | **лог консоли** — здесь видно загрузку и вывод cloud-init |
| Create Snapshot | образ из VM (в Images) |
| Resize Instance | сменить flavor (потом **Confirm Resize**) |
| Soft / Hard Reboot | перезагрузка ОС / «кнопкой питания» |
| Shut Off / Start | выключить / включить |
| Rebuild Instance | переустановить с образа (диск стирается, IP остаётся) |
| Lock / Unlock | защита от случайных действий |
| Delete Instance | удалить |

На странице VM (клик по имени) вкладки: **Overview** (ID, IP, flavor, образ, ошибка при `Error`), **Interfaces**, **Log**, **Console**, **Action Log** (история действий).

### Получить доступ для CLI

**Project → API Access**:

* **Download OpenStack RC File** — shell-скрипт с переменными окружения;
* **Download clouds.yaml** (в новых версиях) — конфиг для CLI, Terraform, Ansible;
* **View Credentials** — эндпоинт Keystone и ID проекта.

Для CI и Terraform — **Identity → Application Credentials → Create** (если включено у провайдера): отдельный ключ с ограниченными ролями и сроком жизни вместо личного пароля.

## CLI: python-openstackclient

Одна утилита `openstack` для всех сервисов.

```bash
# в venv, чтобы не ломать системный Python
python3 -m venv ~/.venvs/openstack && source ~/.venvs/openstack/bin/activate
pip install python-openstackclient
pip install python-octaviaclient python-heatclient python-designateclient   # плагины (по необходимости)

openstack --version
openstack help server create
```

### Аутентификация: вариант 1 — RC-файл

```bash
# devops-lab-openrc.sh (скачан из Horizon, упрощённо)
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_PROJECT_NAME="devops-lab"
export OS_PROJECT_DOMAIN_NAME="Default"
export OS_USER_DOMAIN_NAME="Default"
export OS_USERNAME="alex"
export OS_REGION_NAME="RegionOne"
export OS_INTERFACE=public
export OS_IDENTITY_API_VERSION=3
read -sr -p "Password: " OS_PASSWORD && export OS_PASSWORD   # пароль спрашивается, не хранится в файле
```

```bash
source devops-lab-openrc.sh
openstack token issue          # проверка: выдан токен — значит, аутентификация работает
```

### Аутентификация: вариант 2 — clouds.yaml (удобнее)

```yaml
# ~/.config/openstack/clouds.yaml
clouds:
  lab:
    auth:
      auth_url: https://keystone.example.com:5000/v3
      username: alex
      project_name: devops-lab
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    interface: public
    identity_api_version: 3

  ci:                                        # application credential для Terraform/CI
    auth_type: v3applicationcredential
    auth:
      auth_url: https://keystone.example.com:5000/v3
      application_credential_id: 1b2c3d...
      application_credential_secret: s3cr3t...
    region_name: RegionOne
```

```yaml
# ~/.config/openstack/secure.yaml — пароли отдельно (chmod 600, не в git)
clouds:
  lab:
    auth:
      password: "my-password"
```

```bash
export OS_CLOUD=lab              # или --os-cloud lab в каждой команде
openstack token issue
openstack --os-cloud ci server list
```

Где CLI ищет `clouds.yaml`: текущая папка → `~/.config/openstack/` → `/etc/openstack/`.

Создать application credential из CLI:

```bash
openstack application credential create terraform-ci \
  --role member \
  --expiration 2027-01-01T00:00:00 \
  --description "Terraform в GitLab CI"
# показывает id и secret ОДИН раз — сразу сохрани в секреты CI
```

### Формат вывода

```bash
openstack server list                                  # таблица
openstack server list --long                           # больше колонок
openstack server list -f json                          # JSON — для jq
openstack server list -f value -c Name -c Status       # только значения, без рамок — для скриптов
openstack server show web-1 -f value -c addresses
openstack server show web-1 -f yaml
openstack server list --fit-width                      # таблица по ширине терминала
```

```bash
# ID сервера по имени — в переменную
SERVER_ID=$(openstack server show web-1 -f value -c id)

# все VM в статусе ERROR
openstack server list --status ERROR -f value -c ID -c Name
```

### Что есть в облаке

```bash
openstack catalog list                 # доступные сервисы и их эндпоинты
openstack project list                 # мои проекты
openstack flavor list                  # размеры VM
openstack image list                   # образы
openstack network list --external      # внешние сети (для роутера и floating IP)
openstack availability zone list
openstack quota show                   # квоты проекта
openstack limits show --absolute       # сколько использовано из квот
```

## Сценарий: от пустого проекта до VM в интернете

### 1. Сеть, подсеть, роутер

```bash
openstack network create app-net

openstack subnet create app-subnet \
  --network app-net \
  --subnet-range 10.10.0.0/24 \
  --gateway 10.10.0.1 \
  --dns-nameserver 8.8.8.8

openstack router create app-router
openstack router set app-router --external-gateway public      # имя внешней сети — из `network list --external`
openstack router add subnet app-router app-subnet
```

### 2. Security group

```bash
openstack security group create web-sg --description "SSH + HTTP"

openstack security group rule create web-sg --protocol tcp --dst-port 22  --remote-ip 203.0.113.10/32   # SSH только со своего IP
openstack security group rule create web-sg --protocol tcp --dst-port 80  --remote-ip 0.0.0.0/0
openstack security group rule create web-sg --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0
openstack security group rule create web-sg --protocol icmp

openstack security group rule list web-sg
```

> По умолчанию правило — входящее (`--ingress`). Исходящий трафик в новой группе разрешён автоматически.

### 3. SSH-ключ

```bash
openstack keypair create --public-key ~/.ssh/id_ed25519.pub alex-key
openstack keypair list
```

### 4. VM с cloud-init

```bash
openstack server create web-1 \
  --flavor m1.small \
  --image "Ubuntu 24.04" \
  --network app-net \
  --security-group web-sg \
  --key-name alex-key \
  --user-data cloud-init.yaml \
  --wait                               # ждать статуса ACTIVE

openstack server show web-1 -c status -c addresses -c flavor -c image
```

`cloud-init.yaml` — любой пример из раздела [cloud-init](cloud-init.md). Дополнительно:

| Флаг | Зачем |
|---|---|
| `--boot-from-volume 20` | корневой диск — volume на 20 ГБ, созданный из образа (поведение при удалении VM зависит от версии клиента — проверь `openstack help server create`) |
| `--config-drive true` | метаданные через диск, а не metadata service (если сеть к 169.254.169.254 не работает) |
| `--availability-zone nova` | конкретная зона |
| `--hint group=<server-group-id>` | поместить в server group (anti-affinity) |
| `--property role=web` | метаданные VM |
| `--min 3 --max 3` | создать сразу 3 одинаковых VM |

### 5. Floating IP и вход

```bash
openstack floating ip create public                       # выделить адрес из внешней сети
openstack floating ip list
openstack server add floating ip web-1 203.0.113.25

ssh ubuntu@203.0.113.25
```

### 6. Проверить, что cloud-init отработал

```bash
openstack console log show web-1 --lines 80 | grep -i cloud-init    # без SSH, из консоли VM
ssh ubuntu@203.0.113.25 'cloud-init status --wait --long'
```

Подробно про проверку — [cloud-init](cloud-init.md), раздел «Проверка работы cloud-init».

## Управление VM

```bash
openstack server list
openstack server show web-1
openstack server stop web-1
openstack server start web-1
openstack server reboot web-1                    # soft
openstack server reboot --hard web-1             # «кнопкой питания»
openstack server delete web-1 --wait

# сменить размер
openstack server resize --flavor m1.medium web-1
openstack server list --name web-1               # статус VERIFY_RESIZE
openstack server resize confirm web-1            # в старых версиях: openstack server resize --confirm web-1
openstack server resize revert web-1             # или откатить

# переустановить ОС с образа (данные на корневом диске пропадут)
openstack server rebuild --image "Ubuntu 24.04" web-1

# снапшот VM → образ в Glance
openstack server image create --name web-1-2026-09-30 --wait web-1

# консоль и история
openstack console url show web-1                 # ссылка на VNC-консоль
openstack console log show web-1 --lines 50      # лог загрузки
openstack server event list web-1                # история действий (create, reboot, resize…)
openstack server event show web-1 <request-id>   # подробности, в том числе ошибка
```

### Статусы VM

| Статус | Значит |
|---|---|
| `BUILD` | создаётся |
| `ACTIVE` | работает |
| `SHUTOFF` | выключена (ресурсы квоты заняты!) |
| `REBOOT` / `HARD_REBOOT` | перезагружается |
| `RESIZE` → `VERIFY_RESIZE` | меняется flavor, ждёт подтверждения |
| `ERROR` | не удалось — причина в поле `fault` |
| `SHELVED_OFFLOADED` | «отложена»: диск сохранён, ресурсы гипервизора освобождены (`server shelve` / `unshelve`) |

## Диски (Cinder)

```bash
openstack volume type list                           # типы дисков (ssd, hdd…)
openstack volume create --size 20 --type ssd data-1
openstack server add volume web-1 data-1             # в VM появится /dev/vdb
openstack volume list
openstack server remove volume web-1 data-1

openstack volume snapshot create --volume data-1 data-1-snap
openstack volume create --snapshot data-1-snap --size 20 data-1-restored
openstack volume set --size 40 data-1                # увеличить (часто только в статусе available)
openstack volume delete data-1
```

Внутри VM после подключения: `lsblk`, `sudo mkfs.ext4 /dev/vdb`, смонтировать и прописать в `/etc/fstab` по `UUID` (или через `mounts`/`fs_setup` в cloud-init).

## Образы (Glance)

```bash
# загрузить официальный облачный образ
curl -LO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
openstack image create "ubuntu-24.04-custom" \
  --file noble-server-cloudimg-amd64.img \
  --disk-format qcow2 \
  --container-format bare \
  --property os_distro=ubuntu \
  --private

openstack image list --private
openstack image show ubuntu-24.04-custom -c status -c size -c min_disk
openstack image delete ubuntu-24.04-custom
```

Свои образы удобно собирать **Packer**-ом (builder `openstack`): VM → настройка → снапшот → образ.

## Балансировщик (Octavia)

```bash
pip install python-octaviaclient

openstack loadbalancer create --name web-lb --vip-subnet-id app-subnet --wait
openstack loadbalancer listener create --name web-http --protocol HTTP --protocol-port 80 web-lb --wait
openstack loadbalancer pool create --name web-pool --lb-algorithm ROUND_ROBIN \
  --listener web-http --protocol HTTP --wait
openstack loadbalancer healthmonitor create --delay 5 --timeout 3 --max-retries 3 \
  --type HTTP --url-path /health web-pool --wait
openstack loadbalancer member create --subnet-id app-subnet --address 10.10.0.11 --protocol-port 80 web-pool
openstack loadbalancer member create --subnet-id app-subnet --address 10.10.0.12 --protocol-port 80 web-pool

openstack loadbalancer show web-lb -c vip_address -c provisioning_status -c operating_status
openstack loadbalancer member list web-pool          # operating_status ONLINE / ERROR
# публичный адрес: floating IP на vip_port_id балансировщика
openstack floating ip set --port $(openstack loadbalancer show web-lb -f value -c vip_port_id) 203.0.113.30
```

> Операции Octavia асинхронные: пока балансировщик в `PENDING_UPDATE`, следующая команда вернёт ошибку — отсюда `--wait`.

## Объектное хранилище (Swift / S3)

```bash
openstack container create backups
openstack object create backups db-2026-09-30.dump
openstack object list backups
openstack object save backups db-2026-09-30.dump
openstack object delete backups db-2026-09-30.dump
```

Многие облака дают к нему и **S3-совместимый** доступ (`openstack ec2 credentials create` → ключи для `aws s3 --endpoint-url ...`, restic, Terraform backend).

## Anti-affinity: разнести VM по хостам

```bash
openstack server group create --policy anti-affinity web-group
GROUP_ID=$(openstack server group show web-group -f value -c id)

for i in 1 2 3; do
  openstack server create web-$i --flavor m1.small --image "Ubuntu 24.04" \
    --network app-net --key-name alex-key --security-group web-sg \
    --hint group=$GROUP_ID --wait
done
```

Упадёт один гипервизор — упадёт одна VM, а не все три.

## Уборка

Удалять в обратном порядке — иначе «ресурс используется»:

```bash
openstack server remove floating ip web-1 203.0.113.25
openstack floating ip delete 203.0.113.25           # неиспользуемые floating IP часто стоят денег
openstack server delete web-1 --wait
openstack volume delete data-1
openstack router remove subnet app-router app-subnet
openstack router unset --external-gateway app-router
openstack router delete app-router
openstack subnet delete app-subnet
openstack network delete app-net
openstack security group delete web-sg
openstack keypair delete alex-key
```

## Terraform и Ansible

Руками через CLI — для изучения и отладки. Постоянная инфраструктура — кодом.

### Terraform

```hcl
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

provider "openstack" {
  cloud = "ci"                        # запись из clouds.yaml (или переменные OS_*)
}

data "openstack_networking_network_v2" "public" {
  name = "public"
}

resource "openstack_compute_instance_v2" "web" {
  name            = "web-1"
  flavor_name     = "m1.small"
  image_name      = "Ubuntu 24.04"
  key_pair        = "alex-key"
  security_groups = ["web-sg"]
  user_data       = file("${path.module}/cloud-init.yaml")

  network {
    name = "app-net"
  }
}

resource "openstack_networking_floatingip_v2" "web" {
  pool = data.openstack_networking_network_v2.public.name
}

resource "openstack_networking_floatingip_associate_v2" "web" {
  floating_ip = openstack_networking_floatingip_v2.web.address
  port_id     = openstack_compute_instance_v2.web.network[0].port
}

output "web_ip" {
  value = openstack_networking_floatingip_v2.web.address
}
```

> Имена ресурсов и мажорная версия провайдера меняются — сверяйся с документацией `terraform-provider-openstack` для своей версии.

### Ansible

Коллекция `openstack.cloud` — и модули, и динамический inventory:

```bash
ansible-galaxy collection install openstack.cloud
pip install openstacksdk
```

```yaml
# inventory/openstack.yml — хосты берутся из облака
plugin: openstack.cloud.openstack
all_projects: false
expand_hostvars: true
```

```bash
ansible-inventory -i inventory/openstack.yml --graph
```

```yaml
- name: Создать VM
  openstack.cloud.server:
    cloud: lab
    name: web-1
    image: Ubuntu 24.04
    flavor: m1.small
    key_name: alex-key
    network: app-net
    security_groups: [web-sg]
    userdata: "{{ lookup('file', 'cloud-init.yaml') }}"
    auto_ip: true
    wait: true
```

## Диагностика

| Симптом | Где смотреть | Частые причины |
|---|---|---|
| VM в `ERROR` | `openstack server show web-1 -c fault` | `No valid host was found` — нет ресурсов на гипервизорах или не подходит flavor/AZ; превышена квота |
| `Quota exceeded for cores/ram/instances` | `openstack limits show --absolute`, Horizon → Overview | квота проекта; выключенные VM тоже занимают квоту |
| VM `ACTIVE`, но не пингуется floating IP | security group, `openstack router show app-router` (есть ли `external_gateway_info`), `openstack port list --server web-1` | нет правила ICMP/SSH; у роутера нет внешнего шлюза; подсеть не подключена к роутеру |
| SSH: `Permission denied (publickey)` | `openstack server show web-1 -c key_name`, лог консоли | VM создана без key pair; не тот пользователь для образа |
| SSH: `Connection timed out` | security group, лог консоли | нет правила на 22; VM ещё грузится; неправильный IP |
| cloud-init не отработал | `openstack console log show web-1` | нет доступа к metadata service (попробовать `--config-drive true`); ошибка в user-data — см. [cloud-init](cloud-init.md) |
| Не удаляется сеть / роутер | `openstack port list --network app-net` | остались порты (VM, балансировщик, интерфейс роутера) |
| Octavia: `Invalid state PENDING_UPDATE` | `openstack loadbalancer show web-lb` | предыдущая операция ещё идёт — `--wait` |
| CLI: `The request you have made requires authentication (HTTP 401)` | `openstack token issue` | неверный пароль/домен/проект, истёк application credential |
| CLI: `Could not find versioned identity endpoints` | `echo $OS_AUTH_URL` | неправильный `auth_url` (нет `/v3`, не тот порт) |

Пользователь по умолчанию в облачных образах:

| Образ | Пользователь |
|---|---|
| Ubuntu | `ubuntu` |
| Debian | `debian` |
| Rocky / Alma / CentOS Stream | `rocky` / `almalinux` / `cloud-user` |
| Fedora | `fedora` |

> Отладочный флаг `--debug` у любой команды `openstack` показывает HTTP-запросы к API и ответы — видно, какой сервис и почему вернул ошибку.

## Частые ошибки

| Ошибка | Последствие | Как правильно |
|---|---|---|
| Пароль в `clouds.yaml` в git | утечка доступа ко всему проекту | пароли в `secure.yaml` вне git, в CI — application credentials |
| SSH открыт на `0.0.0.0/0` | перебор паролей и сканеры | только свой IP / VPN / бастион |
| Выключенные VM «для экономии» | квота занята, в публичном облаке может тарифицироваться | `server shelve` или удалить |
| Забытые floating IP и volume после удаления VM | лишние расходы, исчерпание квоты | уборка по списку, всё через Terraform |
| Корневой диск только эфемерный | данные пропадут при удалении/rebuild VM | данные — на отдельном volume |
| Ресурсы создаются руками в Horizon | нельзя воспроизвести, непонятно, кто и зачем создал | Terraform / Ansible, Horizon — для просмотра и отладки |

## Best Practices

* **clouds.yaml + `OS_CLOUD`** вместо RC-файлов, пароли — в `secure.yaml`.
* **Application credentials** для Terraform, Ansible и CI — с минимальной ролью и сроком жизни.
* **Network Topology в Horizon** — первым делом, когда непонятно, почему нет связи.
* **`-f value -c ...` и `-f json`** в скриптах, а не парсинг таблиц.
* **`--wait`** для операций, после которых идут следующие шаги.
* **Anti-affinity server groups** для реплик одного сервиса.
* **Данные на volume-ах**, VM — пересоздаваемые (cloud-init + Ansible или свой образ).
* **Вся постоянная инфраструктура — в Terraform**, CLI — для изучения и диагностики.
