# Диплом: Terraform и облако

Как описана и развёрнута инфраструктура Momo Store в Yandex Cloud.
Общий обзор — [на главной странице раздела](diploma-momo-store.md).

## Подготовка облака

1. Собственная **организация** Yandex Cloud, в ней облако и каталог `default`.
2. **Платёжный аккаунт** привязан к облаку, промокод активирован (грант 10 000 ₽).
3. **Квоты** подняты до нужных (см. ниже) — стартовых не хватает даже на один узел.
4. Установлены инструменты:

```bash
# Terraform: из основного Homebrew убран после смены лицензии — ставится из tap HashiCorp
brew install hashicorp/tap/terraform        # Terraform 1.17

# yc CLI
curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
```

!!! note "fish shell"
    Установщик `yc` прописывает PATH только в bash/zsh. В fish — **прямо в терминале**, не через `fish -c`:
    ```fish
    fish_add_path ~/yandex-cloud/bin
    yc init        # OAuth-токен → облако → каталог → зона ru-central1-a
    ```

Проверить доступные версии Kubernetes — выбрал **1.34** (1.32 самая старая в списке, скоро снимут):

```bash
yc managed-kubernetes list-versions
```

### Зеркало провайдеров

`registry.terraform.io` из РФ может быть недоступен — провайдеры качаются с зеркала Yandex Cloud.
Файл `infrastructure/terraform/.terraformrc`:

```hcl
provider_installation {
  network_mirror {
    url     = "https://terraform-mirror.yandexcloud.net/"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
```

```fish
set -x TF_CLI_CONFIG_FILE ~/Documents/pr_repo/momo-store/infrastructure/terraform/.terraformrc
```

Через зеркало провайдер ставится как `(unauthenticated)` и в `.terraform.lock.hcl` попадают хэши только
текущей платформы. Чтобы `terraform init` не падал в CI на Linux — добавить хэши всех платформ:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```

### Квоты

Стартовые квоты нового облака (на зону `ru-central1-a`): **2 vCPU, 16 ГБ RAM, 20 ГБ HDD, 10 ГБ SSD**.
Без увеличения кластер создаётся, а ВМ узлов падают с `RESOURCE_EXHAUSTED`.

| Квота | Было | Стало | Расчёт |
|---|---|---|---|
| `compute.instanceCores.count.ru-central1-a` | 2 | **4** | 2 узла × 2 vCPU |
| `compute.hddDisks.size.ru-central1-a` | 20 ГБ | **150 ГБ** | 2 × 64 ГБ + 10 ГБ PVC Prometheus + запас |
| `compute.instanceMemory.size.ru-central1-a` | 16 ГБ | 24 ГБ | хватало и 16 (2 × 8 ГБ) |

Для 3 узлов нужно 6 vCPU / 24 ГБ / 210 ГБ HDD. Заявки на такие значения одобрились автоматически за минуты.

```bash
# посмотреть квоты
yc quota-manager quota-limit list --service compute \
  --resource-type resource-manager.cloud --resource-id <cloud_id> | grep ru-central1-a
```

!!! tip "Квоты — это лимит, а не оплата"
    Поднятая квота ничего не стоит. Платишь только за созданные ресурсы.

## Две конфигурации и где state

```
bootstrap/        →  SA terraform (роль admin на каталог) + его ключи + бакет для state
                     state: сначала локально, потом перенесён в бакет → bootstrap/terraform.tfstate
envs/prod/        →  вся остальная инфраструктура
                     state: s3://<state_bucket>/prod/terraform.tfstate
```

**Курица и яйцо:** state хранится в бакете, а бакет создаёт Terraform. Поэтому bootstrap запускается
с **локальным** state, а после `apply` state переносится в созданный им же бакет (`-migrate-state`).

Почему у SA `terraform` роль **`admin`**, а не `editor`: основная конфигурация сама создаёт сервисные
аккаунты и **назначает им роли** — `editor` этого не умеет.

Бакет state: приватный, **версионирование** включено (можно откатить испорченный state),
старые версии удаляются через 30 дней. **Блокировок нет** — работаю один со своего Mac,
CI state не трогает (только `validate`). Для команды блокировку делают через serverless YDB.

## Bootstrap — пошагово

```bash
cd infrastructure/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars    # cloud_id, folder_id, state_bucket_name
export YC_TOKEN=$(yc iam create-token)          # авторизация от своего имени, живёт 12 ч
terraform init
terraform plan -out=tfplan                      # 5 to add
terraform apply tfplan
```

Ресурсы bootstrap (`main.tf`):

```hcl
resource "yandex_iam_service_account" "terraform" { name = "terraform" }

resource "yandex_resourcemanager_folder_iam_member" "terraform_admin" {
  folder_id = var.folder_id
  role      = "admin"
  member    = "serviceAccount:${yandex_iam_service_account.terraform.id}"
}

resource "yandex_iam_service_account_key" "terraform" { ... }               # для провайдера
resource "yandex_iam_service_account_static_access_key" "terraform" { ... } # для S3-backend

resource "yandex_storage_bucket" "tfstate" {
  bucket     = var.state_bucket_name
  access_key = yandex_iam_service_account_static_access_key.terraform.access_key
  secret_key = yandex_iam_service_account_static_access_key.terraform.secret_key
  versioning { enabled = true }
  anonymous_access_flags { read = false  list = false  config_read = false }
  lifecycle_rule {
    id      = "expire-old-state-versions"
    enabled = true
    noncurrent_version_expiration { days = 30 }
  }
}
```

Ключ SA в формате `yc iam key create` собирается в output через `jsonencode` (поля `id`,
`service_account_id`, `created_at`, `key_algorithm`, `public_key`, `private_key`).

Сохранить ключи **вне репозитория** и перенести state:

```bash
mkdir -p ~/.config/yandex-cloud
(umask 077
 terraform output -raw terraform_sa_key_json > ~/.config/yandex-cloud/momo-terraform-key.json
 printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
   "$(terraform output -raw s3_access_key)" "$(terraform output -raw s3_secret_key)" \
   > ~/.config/yandex-cloud/momo-s3.env)
echo "bucket = \"$(terraform output -raw state_bucket)\"" | tee backend.hcl > ../envs/prod/backend.hcl

set -a; . ~/.config/yandex-cloud/momo-s3.env; set +a
cp backend.tf.example backend.tf                # backend "s3", key = bootstrap/terraform.tfstate
terraform init -migrate-state -force-copy -backend-config=backend.hcl
terraform plan                                  # No changes — state читается из бакета
rm -f terraform.tfstate terraform.tfstate.backup  # в локальной копии ключи открытым текстом
```

!!! warning "После переноса `terraform output` сам требует S3-ключи"
    State теперь в бакете, и даже чтобы прочитать output, нужны `AWS_ACCESS_KEY_ID/SECRET`.
    Поэтому ключи S3 сохранены в отдельный файл `momo-s3.env` **до** удаления локального state.

В fish переменные из env-файла загружаются так:

```fish
for l in (cat ~/.config/yandex-cloud/momo-s3.env); set -gx (string split -m1 = $l); end
```

## Основная инфраструктура — envs/prod

!!! note "Фрагменты сокращены"
    Блоки HCL ниже ужаты для конспекта (несколько аргументов в одной строке, `...` вместо очевидного).
    В настоящем HCL каждый аргумент вложенного блока пишется с новой строки — полная версия в репозитории.

Backend (`versions.tf`) — **partial configuration**: имя бакета приходит из `backend.hcl`, ключи — из env:

```hcl
terraform {
  backend "s3" {
    key    = "prod/terraform.tfstate"
    region = "ru-central1"
    endpoints = { s3 = "https://storage.yandexcloud.net" }

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

# авторизация провайдера — export YC_SERVICE_ACCOUNT_KEY_FILE=...
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}
```

`skip_*` нужны, потому что S3-backend рассчитан на AWS: без них он пытается проверить регион
и учётку через AWS STS.

Запуск:

```bash
cd infrastructure/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars          # cloud_id, folder_id, static_bucket_name
set -a; . ~/.config/yandex-cloud/momo-s3.env; set +a
export YC_SERVICE_ACCOUNT_KEY_FILE=~/.config/yandex-cloud/momo-terraform-key.json
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan                            # 38 to add
terraform apply tfplan                                # 15–20 мин (у меня 44 — ждал квоты)
terraform output
```

Результат `plan`: **38 to add, 0 to change, 0 to destroy**.

| Модуль | Ресурсы |
|---|---|
| `network` | VPC, NAT-шлюз (`shared_egress_gateway`), таблица маршрутов `0.0.0.0/0 → NAT`, подсеть 10.10.0.0/24, статический IP |
| `kubernetes` | 2 SA (кластер, узлы), 3 роли кластеру, KMS-ключ + binding, 3 группы безопасности, кластер, группа узлов |
| `registry` | реестр, 2 репозитория, 2 политики очистки, IAM pull (узлы) и push (CI) на уровне реестра |
| `storage` | SA + статический ключ, роль `storage.admin`, публичный бакет, 8 объектов-картинок |
| корень | SA GitLab CI + авторизованный ключ |

### Модуль network

```hcl
resource "yandex_vpc_gateway" "nat" {
  name = "${var.name}-nat"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "nat" {
  network_id = yandex_vpc_network.this.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_address" "ingress" {         # IP для LoadBalancer ingress-nginx
  external_ipv4_address { zone_id = var.zone }
}
```

Узлы без публичных IP (`nat = false`) — наружу через NAT. Статический IP не меняется при пересоздании
кластера, поэтому `APP_URL` в CI менять не нужно.

### Модуль kubernetes

**IAM** — `iam_member`, а **не** `iam_binding`:

```hcl
locals {
  cluster_roles = toset(["k8s.clusters.agent", "vpc.publicAdmin", "load-balancer.admin"])
}
resource "yandex_resourcemanager_folder_iam_member" "cluster" {
  for_each  = local.cluster_roles
  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.cluster.id}"
}
```

!!! danger "iam_binding авторитативен"
    `yandex_resourcemanager_folder_iam_binding` задаёт **полный** список участников роли и сотрёт всех
    остальных, кому эта роль была выдана руками. В репо 2022 года так и было — легко снести себе доступ.

**Группы безопасности** — по рекомендациям документации Managed Kubernetes:

| Группа | Правила |
|---|---|
| `main` (мастер + узлы) | health checks NLB из `198.18.235.0/24`, `198.18.248.0/24`; весь трафик внутри группы (`self_security_group`); трафик подов и сервисов (CIDR кластера); ICMP из приватных сетей; весь исходящий |
| `nodes_public` (узлы) | TCP 30000–32767 из интернета — NodePort, куда NLB шлёт трафик |
| `master` | TCP 443 и 6443 из `api_allowed_cidrs` (по умолчанию `0.0.0.0/0`: IP раннеров GitLab неизвестны) |

**Кластер:**

```hcl
resource "yandex_kubernetes_cluster" "this" {
  master {
    version   = var.k8s_version              # "1.34"
    public_ip = true
    zonal { zone = var.zone  subnet_id = var.subnet_id }
    security_group_ids = [main, master]
    maintenance_policy { auto_upgrade = true  maintenance_window { day = "monday" start_time = "02:00" duration = "3h" } }
  }
  cluster_ipv4_ranges     = [var.cluster_ipv4_range]   # 10.112.0.0/16 (старый cluster_ipv4_range — deprecated)
  service_ipv4_range      = var.service_ipv4_range     # 10.96.0.0/16
  release_channel         = "REGULAR"
  network_policy_provider = "CALICO"                   # ← без этого NetworkPolicy игнорируются
  kms_provider { key_id = yandex_kms_symmetric_key.secrets.id }
}
```

!!! warning "Calico — только при создании"
    `network_policy_provider` нельзя включить на существующем кластере — только пересозданием.
    Поэтому включил сразу, хотя zero-trust — задача со звёздочкой.

**Группа узлов:**

```hcl
resource "yandex_kubernetes_node_group" "this" {
  instance_template {
    platform_id = "standard-v3"
    resources { cores = 2  memory = 8  core_fraction = 50 }
    boot_disk { type = "network-hdd"  size = 64 }
    scheduling_policy { preemptible = true }          # прерываемые ВМ
    network_interface { subnet_ids = [...]  nat = false  security_group_ids = [main, nodes_public] }
    container_runtime { type = "containerd" }
  }
  scale_policy { auto_scale { min = 2  max = 2  initial = 2 } }
  node_labels = { "preemptible" = "true" }          # для nodeSelector DaemonSet'а
  maintenance_policy { auto_upgrade = true  auto_repair = true }
}
```

`auto_scale` с `min = max = 2` оставлен специально: смена на `fixed_scale` **пересоздала бы** группу узлов,
а так для третьего узла достаточно поднять квоты и `node_max_count = 3`.

### Модуль registry

```hcl
resource "yandex_container_repository_lifecycle_policy" "this" {
  rule { description = "Untagged" untagged = true expire_period = "48h" }
  rule {
    description   = "SHA-сборки"
    tag_regexp    = "^[0-9a-f]{8}$"          # CI_COMMIT_SHORT_SHA — 8 символов
    untagged      = false
    retained_top  = 20
    expire_period = "168h"
  }
}

# роли на уровне реестра, а не каталога — минимальные привилегии
resource "yandex_container_registry_iam_binding" "puller" { role = "container-registry.images.puller" ... }  # SA узлов
resource "yandex_container_registry_iam_binding" "pusher" { role = "container-registry.images.pusher" ... }  # SA CI
```

Ноды тянут образы по IAM-роли — **никаких `imagePullSecrets`** (в репо 2022 был секрет из личного `~/.docker/config.json`).

### Модуль storage

```hcl
resource "yandex_storage_bucket" "static" {
  anonymous_access_flags { read = true  list = false  config_read = false }   # объекты читаются, листинг закрыт
  cors_rule { allowed_methods = ["GET", "HEAD"]  allowed_origins = ["*"]  max_age_seconds = 3600 }
}

resource "yandex_storage_object" "static" {
  for_each     = fileset(var.static_dir, "**")
  key          = "images/${each.value}"
  source       = "${var.static_dir}/${each.value}"
  source_hash  = filemd5("${var.static_dir}/${each.value}")      # перезалить при изменении файла
  content_type = lookup(local.content_types, lower(reverse(split(".", each.value))[0]), "application/octet-stream")
}
```

Картинки скачаны с исходного CDN (Cloudinary) в `infrastructure/static/images/`. Проверка:

```bash
curl -I https://storage.yandexcloud.net/<static_bucket>/images/<file>.jpg   # 200
curl -I https://storage.yandexcloud.net/<static_bucket>/                     # 403 — листинг закрыт
```

### Outputs

```
cluster_id, cluster_endpoint
kubeconfig_command = "yc managed-kubernetes cluster get-credentials <id> --external --force"
registry_url       = "cr.yandex/<registry_id>"
ingress_ip         = "<ingress_ip>"
static_base_url    = "https://storage.yandexcloud.net/<static_bucket>/images"
ci_sa_key_json     = <sensitive>
```

## Проверка соответствия коду

```bash
terraform plan -detailed-exitcode
# No changes. Your infrastructure matches the configuration.   → exit 0 (2 = есть изменения)
```

Это пункт чек-листа «состояние инфраструктуры полностью соответствует описанию в коде».

## Экономия гранта

* Мастер тарифицируется **постоянно**, пока кластер существует; узлы, NAT — тоже.
  Сеть, IP, реестр, бакеты, KMS — копейки.
* Бюджет с уведомлениями: Биллинг → Бюджеты (пороги 50 % и 80 %).
* Реальная цена суток: Биллинг → Детализация (появляется с задержкой в несколько часов).
* Погасить кластер, оставив всё остальное:

```bash
terraform destroy -target=module.kubernetes
# вернуть: terraform apply → k8s-addons/install.sh → перевыпустить KUBECONFIG для CI → деплой тега
```

!!! warning "Перед отправкой наставнику кластер должен быть поднят"
    Проверяют работающее приложение по ссылке.

## Шпаргалка команд

| Команда | Зачем |
|---|---|
| `terraform fmt -recursive -check` | форматирование |
| `terraform init -backend=false && terraform validate` | проверка без доступа к state (так в CI) |
| `terraform plan -out=tfplan` / `terraform show tfplan` | сохранить и посмотреть план |
| `terraform apply tfplan` | применить ровно сохранённый план |
| `terraform state list` | что под управлением |
| `terraform output -raw <name>` | значение output без кавычек |
| `terraform init -migrate-state -force-copy` | перенести state в новый backend |
| `terraform providers lock -platform=...` | хэши провайдера для других ОС |
| `terraform providers schema -json \| jq` | схема ресурса: какие аргументы, что deprecated |
| `yc managed-kubernetes node-group list-nodes <name>` | статус ВМ узлов — тут видна ошибка квоты |
