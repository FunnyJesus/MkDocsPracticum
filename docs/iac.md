# IaС
IaС - подход, при котором вся инфраструктура описывется как код: виртуальные машины, балансировщики, сети и ПО. Итоговые манифесты можно масштабировать и при этом наглядно выдеть, что будет создаваться. 
Для такого должно быть предоставлено API для управления ресурсами. 


## Terraform
* Terrafom - инструмент для автоматизации развертивания и управления IT-инфраструктурой по подходу IaC
> После установки terraform требует настройки зеркал, устновки нужной версии провайдера и авторизации. 
> Все определяется облаком или api, с которым нужно работать

!!! Подсказка 
        Важно помнить различие plan, state и какие изменения должны быть применены. 
        Одни параметры могут пересоздать ресурс

## Структура 
```
тип_блока "вид_описываемой_сущности" "имя_сущности"{
 # решётка — это комментарий;
 # "имя_сущности" — опциональный параметр, иногда его нет.
 
 // кстати, два слеша — это тоже комментарий.
 
 # ниже описаны атрибуты блока
 # в отличие от JSON, HCL не требует фигурных скобок вокруг атрибутов и использует знак равенства вместо двоеточия.
 ключ1 = значение1 
 ключ2 = значение2
}
```
### Основные верхнеуровневые блоки в Terraform (в одном каталоге модуля):
#### terraform
* `terraform` — настройки самого Terraform: ограничения версии CLI и провайдеров, бэкенд для state, эксперименты. Это не описание «железа» в облаке.
```
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      # Можно указать версию провайдера, с которой будет работать конфигурация.
      version = ">= 0.87.0"
    }
  }
  # Также можно указать версию CLI Terraform.
  required_version = ">= 0.13"
}
```
#### provider 
* `provider` — как подключаться к API платформы (учётка, регион/зона по умолчанию, эндпоинты). Один провайдер может обслуживать много ресурсов.
```
# Зона доступности (Availability Zone), где по умолчанию будут создаваться все ресурсы:
provider "yandex" {
  zone      = "ru-central1-a"
}
```
#### resource
* `resource` — создание и управление сущностью в инфраструктуре (ВМ, сеть, диск и т.д.); Terraform будет приводить реальное состояние к описанному в блоке.
```
# Тип блока, тип ресурса, имя блока
resource "yandex_compute_instance" "vm-1" {
        // Описание параметров следует смотреть в документации по API.
        // В данном случае документаци yandex.cloud
}
```
#### data 
* `data` — только чтение: ссылка на уже существующие объекты или внешние данные без обязательного управления ими из этого манифеста (часто — чтобы подставить ID в resource).
```
data "yandex_vpc_subnet" "default_subnet" {
  name = "default-ru-central1-a"
} 

// Вызов output-переменной в resourse

resiurse "instance_compute" "vm" {
  ...
  network_interface {
     subnet_id = data.yandex_vpc_subnet.default_subnet.id // Получение id подсети
        }
}
```
#### variable
* `variable` — входные параметры модуля; значения задаются через CLI, файлы .tfvars, CI и т.д.
```
variable "extra_disk_type" { // объявление переменной
  description = "Тип дополнительного диска" // Заметка или описание переменной
  type    = string // тип переменной
  default = "network-hdd" // Значение по умолчанию
}

variable "extra_disk_names" {
    description = "Имена дополнительных дисков "
    type = list(string)
}

variable "extra_disk_size" {
  description = "Размер дополнительного диска"
  type    = number
}

variable "ssh_public_key" {
    description = "Ssh public key for vm"
    type = string
    default = null
}

variable "vm_specification" {
  description = "Конфигурация ВМ для каждого модуля"
  type = map(object({
    cores     = number
    memory    = number
    disk_size = number
    boot_disk = string
  }))
}

```
#### locals
* `locals` — локальные вычисляемые значения внутри модуля: удобно собрать имя, список зон или повторяющееся выражение в одном месте, не создавая ресурс в облаке.
```
locals { // Объявление блока
        value = key
        value_2 = key_2 
        // объявление переменных
}

resource "instance_compute" "vm" {
        prarm_1 = local.value_2 // вызов переменной в блок resource
}
```
* `output` — что вернуть наружу после apply: IP, ID, DNS — для человека, для другого стека Terraform или для скриптов.
#### module
* `module` — подключение другого каталога с конфигурацией как кирпича: переиспользование и композиция. Разберём отдел
```
├── modules
│   ├── api
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   └── web
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
├── outputs.tf
├── terraform.tfvars
├── terraform.tfvars.dev
├── terraform.tfvars.prod
└── variables.tf

4 directories, 14 files
```
> Вызов модуля. В модуле описан ресурс
```
module "web" {
  source = "./modules/web"
}
```

## Bootstrap: с чего начинается Terraform-проект

### Что это

**Bootstrap** — маленькая отдельная конфигурация Terraform, которая создаёт то, что нужно **самому
Terraform** для работы с остальной инфраструктурой:

| Что создаёт | Зачем |
|---|---|
| бакет (или другое хранилище) для **remote state** | state не на ноутбуке, общий для команды и CI, с версионированием |
| **сервисный аккаунт** для Terraform + роль | Terraform ходит в облако не под личной учёткой |
| **ключи** этого аккаунта: авторизованный (для провайдера) и статический (для S3-backend) | авторизация провайдера и доступ к state |
| (опционально) хранилище для **блокировок** state | два `apply` одновременно не испортят state |

Это фундамент, на котором стоит основная конфигурация (сеть, кластер, реестр…).

### Зачем нужен: курица и яйцо

Основная конфигурация хранит state в бакете — `backend "s3" { bucket = "..." }`. Но бакет — тоже ресурс,
и его должен кто-то создать **до** первого `terraform init`. Создать его той же конфигурацией нельзя:
`init` упадёт раньше, чем дойдёт до `apply`.

```
bootstrap/  ──создаёт──►  бакет для state + SA terraform + ключи
                               │
envs/prod/  ──хранит state в───┘   ──создаёт──►  сеть, кластер, реестр, бакеты...
```

Варианты, как решают:

| Вариант | Плюсы | Минусы |
|---|---|---|
| Создать бакет руками в консоли | быстро | не в коде: нельзя воспроизвести, легко забыть настройки (версионирование) |
| **Отдельная bootstrap-конфигурация** (рекомендуется) | всё в коде, воспроизводимо | сам bootstrap где-то хранит свой state (см. ниже) |
| Managed state (GitLab, HCP Terraform) | бакет не нужен, блокировки «из коробки» | привязка к платформе; SA для облака всё равно нужен |

### Как работать

**1. Первый запуск — с локальным state и под своей учёткой.** Бакета ещё нет, поэтому backend не задан.

```bash
cd infrastructure/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars      # cloud_id, folder_id, имя бакета (глобально уникальное)
export YC_TOKEN=$(yc iam create-token)            # личный токен, живёт 12 ч
terraform init
terraform plan -out=tfplan                        # проверить: только SA, роль, ключи, бакет
terraform apply tfplan
```

```hcl
resource "yandex_iam_service_account" "terraform" { name = "terraform" }

resource "yandex_resourcemanager_folder_iam_member" "terraform" {
  folder_id = var.folder_id
  role      = "admin"            # editor не умеет назначать роли — а основная конфигурация их назначает
  member    = "serviceAccount:${yandex_iam_service_account.terraform.id}"
}

resource "yandex_iam_service_account_key" "terraform" {               # для провайдера
  service_account_id = yandex_iam_service_account.terraform.id
}

resource "yandex_iam_service_account_static_access_key" "terraform" { # для S3-backend
  service_account_id = yandex_iam_service_account.terraform.id
}

resource "yandex_storage_bucket" "tfstate" {
  bucket     = var.state_bucket_name
  access_key = yandex_iam_service_account_static_access_key.terraform.access_key
  secret_key = yandex_iam_service_account_static_access_key.terraform.secret_key
  versioning { enabled = true }                     # бэкап state: можно откатить испорченную версию
  anonymous_access_flags { read = false  list = false }
}
```

**2. Сохранить ключи вне репозитория** — из outputs (они `sensitive`):

```bash
(umask 077
 terraform output -raw sa_key_json > ~/.config/yandex-cloud/terraform-key.json
 printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
   "$(terraform output -raw s3_access_key)" "$(terraform output -raw s3_secret_key)" \
   > ~/.config/yandex-cloud/s3.env)
```

**3. Перенести state bootstrap в созданный им же бакет** — чтобы и он не жил на ноутбуке:

```bash
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    key       = "bootstrap/terraform.tfstate"
    region    = "ru-central1"
    endpoints = { s3 = "https://storage.yandexcloud.net" }
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
EOF
set -a; . ~/.config/yandex-cloud/s3.env; set +a
terraform init -migrate-state -force-copy -backend-config="bucket=<state_bucket>"
terraform plan                                      # No changes — state читается из бакета
rm -f terraform.tfstate terraform.tfstate.backup    # локальные копии содержат ключи открытым текстом
```

**4. Основная конфигурация работает уже от имени SA** и хранит state рядом, под своим ключом:

```bash
cd ../envs/prod
export YC_SERVICE_ACCOUNT_KEY_FILE=~/.config/yandex-cloud/terraform-key.json
set -a; . ~/.config/yandex-cloud/s3.env; set +a
terraform init -backend-config=backend.hcl         # backend.hcl: bucket = "<state_bucket>"
terraform plan
```

Итог — в бакете два state с разными ключами:

```
s3://<state_bucket>/
├── bootstrap/terraform.tfstate
└── prod/terraform.tfstate
```

### Что где хранить

| Что | Где | В git? |
|---|---|---|
| код bootstrap и основной конфигурации | репозиторий | да |
| `terraform.tfvars` (ID облака, имена бакетов) | локально, `*.tfvars.example` — в git | нет |
| `backend.hcl` / `backend.tf` с конкретным бакетом | локально, `.example` — в git | нет |
| ключ SA, S3-ключи | `~/.config/...` с правами 600, в CI — masked/File-переменные | **никогда** |
| state | бакет | **никогда** |

### Блокировки state

Версионирование спасает от порчи, но не от двух одновременных `apply`. Варианты:

- `use_lockfile = true` (Terraform 1.10+) — lock-файл в том же бакете; хранилище должно поддерживать
  условную запись, проверь для своего S3-совместимого сервиса;
- DynamoDB-совместимая таблица (`dynamodb_table`) — в Yandex Cloud это serverless YDB, её тоже
  создаёт bootstrap;
- пока Terraform запускает один человек, а CI делает только `validate` — блокировку можно отложить,
  но записать это как известное ограничение.

### Жизненный цикл

- **Bootstrap запускается редко**: при создании проекта, смене ролей SA, ротации ключей.
- **Удалять — последним.** Основная инфраструктура хранит state в его бакете и работает под его SA:
  сначала `terraform destroy` в `envs/*`, потом bootstrap.
- **Удаление самого bootstrap** — снова курица и яйцо: его state лежит в бакете, который он удаляет.
  Порядок: вернуть state на диск (убрать `backend.tf` → `terraform init -migrate-state`), очистить
  бакет **со всеми версиями** (или `force_destroy = true` + `apply`), затем `terraform destroy`.
- **Оставить bootstrap после уборки** — нормально: пустой бакет и SA почти ничего не стоят, а поднять
  инфраструктуру заново можно одной командой.

### Частые ошибки

| Симптом | Причина |
|---|---|
| `AccessDenied` при создании бакета, хотя у SA `admin` | роль ещё не распространилась (повторить через минуту) или **у облака нет активного биллинга** |
| `No valid credential sources found ... EC2 IMDS` после переноса state | для чтения state нужны S3-ключи в `AWS_ACCESS_KEY_ID/SECRET` |
| `terraform init` падает: бакет не существует (`NoSuchBucket`) | бакет ещё не создан (не запущен bootstrap) или опечатка в `backend.hcl` |
| бакет не удаляется: `BucketNotEmpty` | версионирование: удалены текущие объекты, но не старые версии |
| роль SA «пропала» у других участников | использовали `*_iam_binding` (авторитативный) вместо `*_iam_member` |

Реальный пример с выводами команд — [Диплом: Terraform и облако](diploma-terraform.md);
remote state, блокировки и разделение state — [Terraform: продвинутый уровень](terraform-advanced.md).

> Команды Terraform — на странице [IaC: команды с подробным описанием](iac-commands.md).
> Мини-шпаргалка: [IaC: шпаргалка топ-20 команд](iac-cheatsheet.md).
