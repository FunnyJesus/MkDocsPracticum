# Terraform: продвинутый уровень

> Основы (resource, provider, variable, команды) — [IaC](iac.md), [IaC: команды](iac-commands.md).

Пока Terraform запускает один человек со своего ноутбука, всё просто. Проблемы начинаются, когда появляются команда, несколько окружений и CI: где хранить state, как не запустить `apply` вдвоём одновременно, как не копировать один и тот же код в dev и prod.

## State: что это и почему важно

**State** (`terraform.tfstate`) — файл, в котором Terraform помнит, какие реальные ресурсы соответствуют твоему коду (ID виртуалки, IP, ARN…). Без него Terraform не знает, что уже создано.

* State **содержит секреты** открытым текстом (пароли БД, ключи) — нельзя коммитить в git.
* State **нельзя терять** — иначе Terraform попытается создать всё заново.
* State **нельзя менять одновременно** — два параллельных `apply` испортят его.

## Remote state и блокировки

Решение — хранить state в общем хранилище с **блокировкой** (lock).

### S3 (AWS / любое S3-совместимое: Yandex Object Storage, MinIO)

```hcl
terraform {
  backend "s3" {
    bucket       = "company-terraform-state"
    key          = "prod/network/terraform.tfstate"   # путь внутри бакета
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true      # блокировка через lock-файл в S3 (Terraform 1.10+)
    # раньше: dynamodb_table = "terraform-locks"
  }
}
```

### Другие бэкенды

| Бэкенд | Блокировка | Где |
|---|---|---|
| `s3` | lock-файл в S3 или DynamoDB | AWS, S3-совместимые |
| `gcs` | встроенная | Google Cloud |
| `azurerm` | встроенная (blob lease) | Azure |
| `http` | зависит от сервера | **GitLab** Managed Terraform State |
| HCP Terraform / Terraform Cloud | встроенная | SaaS от HashiCorp |

```bash
terraform init -migrate-state      # перенести локальный state в новый бэкенд
terraform force-unlock <LOCK_ID>   # снять зависшую блокировку (только если уверен, что apply не идёт!)
```

> Бакет для state лучше создать отдельно (руками или отдельным Terraform-проектом), включить **версионирование** — это бэкап state на случай порчи.

## Разделение state

Один огромный state на всю инфраструктуру — плохо: медленный `plan`, большой «радиус поражения», все блокируют друг друга. Делим по окружению и слою:

```
infra/
├── modules/                  # переиспользуемые модули
│   ├── network/
│   └── k8s-cluster/
└── envs/
    ├── dev/
    │   ├── network/          # свой state: dev/network/terraform.tfstate
    │   └── k8s/              # свой state: dev/k8s/terraform.tfstate
    └── prod/
        ├── network/
        └── k8s/
```

Слои меняются с разной частотой: сеть — редко, приложения — часто.

### Чтение outputs другого state

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "company-terraform-state"
    key    = "prod/network/terraform.tfstate"
    region = "eu-central-1"
  }
}

resource "aws_instance" "app" {
  subnet_id = data.terraform_remote_state.network.outputs.private_subnet_id
}
```

## Модули

**Модуль** — папка с `.tf`-файлами, которую можно вызвать много раз с разными параметрами. Как функция в программировании.

```
modules/web-server/
├── main.tf          # ресурсы
├── variables.tf     # входные параметры
├── outputs.tf       # что модуль отдаёт наружу
└── versions.tf      # required_providers
```

```hcl
# modules/web-server/variables.tf
variable "name"          { type = string }
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "subnet_id"     { type = string }
```

```hcl
# modules/web-server/main.tf
resource "aws_instance" "this" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  tags          = { Name = var.name }
}
```

```hcl
# modules/web-server/outputs.tf
output "private_ip" { value = aws_instance.this.private_ip }
```

Вызов:

```hcl
# envs/prod/app/main.tf
module "web" {
  source        = "../../../modules/web-server"
  name          = "web-prod"
  instance_type = "t3.large"
  subnet_id     = data.terraform_remote_state.network.outputs.private_subnet_id
}

output "web_ip" { value = module.web.private_ip }
```

Источники модулей:

```hcl
source = "../modules/vpc"                                         # локальная папка
source = "git::https://github.com/company/tf-modules.git//vpc?ref=v1.3.0"   # git с тегом
source = "terraform-aws-modules/vpc/aws"                          # Terraform Registry
version = "~> 5.0"                                                # (только для registry)
```

> Всегда фиксируй версию модуля (`ref=` / `version`) — иначе обновление модуля неожиданно изменит прод.

## count и for_each

```hcl
# count — N одинаковых ресурсов
resource "aws_instance" "worker" {
  count         = 3
  instance_type = "t3.small"
  tags          = { Name = "worker-${count.index}" }
}

# for_each — по словарю/набору, у каждого ресурса стабильный ключ
variable "buckets" {
  default = {
    logs    = "private"
    backups = "private"
    public  = "public-read"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets
  bucket   = "company-${each.key}"
}
```

> **Предпочитай `for_each`**. С `count` удаление элемента из середины списка сдвигает индексы, и Terraform пересоздаёт все последующие ресурсы.

## Workspaces

Workspace — несколько state-файлов для **одного и того же кода**:

```bash
terraform workspace new dev
terraform workspace new prod
terraform workspace select prod
terraform workspace list
```

```hcl
resource "aws_instance" "app" {
  instance_type = terraform.workspace == "prod" ? "t3.large" : "t3.micro"
}
```

| | Workspaces | Отдельные папки на окружение |
|---|---|---|
| Код | один | вызов одних и тех же модулей из разных папок |
| Отличия окружений | условия в коде | разные значения переменных |
| Риск | легко сделать `apply` не в том workspace | видно по папке, где находишься |
| Когда | временные одинаковые окружения (feature-стенды) | dev / staging / prod |

## Импорт существующих ресурсов

Ресурс создали руками в консоли, теперь хотим управлять им через Terraform:

```hcl
# Terraform 1.5+: декларативный импорт
import {
  to = aws_s3_bucket.legacy
  id = "company-legacy-bucket"
}
```

```bash
terraform plan -generate-config-out=generated.tf   # сгенерировать описание ресурса
terraform apply                                     # импорт в state
```

Старый способ: `terraform import aws_s3_bucket.legacy company-legacy-bucket`.

## Работа со state

```bash
terraform state list                              # все ресурсы в state
terraform state show aws_instance.web             # атрибуты ресурса
terraform state mv aws_instance.web module.web.aws_instance.this   # переименовали/перенесли в модуль
terraform state rm aws_instance.old               # «забыть» ресурс, не удаляя его в облаке
terraform apply -replace=aws_instance.web         # принудительно пересоздать ресурс
```

Вместо `state mv` в коде (Terraform 1.1+):

```hcl
moved {
  from = aws_instance.web
  to   = module.web.aws_instance.this
}
```

## lifecycle

```hcl
resource "aws_db_instance" "main" {
  # ...
  lifecycle {
    prevent_destroy       = true        # запретить удаление (защита прод-базы)
    create_before_destroy = true        # сначала создать новый, потом удалить старый
    ignore_changes        = [tags]      # не трогать поле, которое меняют снаружи
  }
}
```

## Terraform в CI

```yaml
# GitLab CI (упрощённо)
stages: [validate, plan, apply]

validate:
  stage: validate
  script:
    - terraform fmt -check -recursive
    - terraform init -backend=false
    - terraform validate
    - tflint

plan:
  stage: plan
  script:
    - terraform init
    - terraform plan -out=tfplan
  artifacts:
    paths: [tfplan]

apply:
  stage: apply
  script:
    - terraform init
    - terraform apply tfplan          # применяется ровно тот план, который видели на ревью
  when: manual
  only: [main]
```

Популярные инструменты вокруг:

* **tflint** — линтер; **tfsec / checkov / trivy config** — безопасность (см. [Безопасность](security.md));
* **Atlantis** — `plan` и `apply` комментариями в merge request;
* **Terragrunt** — обёртка: DRY-конфигурация бэкендов и зависимостей между слоями;
* **OpenTofu** — open-source форк Terraform (после смены лицензии HashiCorp), совместим по синтаксису.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `Error acquiring the state lock` | идёт другой apply или прошлый упал | дождаться; если точно никто не работает — `force-unlock` |
| Terraform хочет пересоздать всё | потерян/не тот state, не тот workspace/бэкенд | проверить `backend`, `terraform workspace show`, `state list` |
| Удаление элемента списка пересоздаёт остальные | `count` по списку | `for_each` + `moved` |
| `plan` показывает изменения, которых никто не делал | правили ресурс руками (drift) | вернуть в код или `ignore_changes`; руками не править |
| Пароль БД виден в state | state хранит все атрибуты | шифрованный бэкенд, ограничить доступ к state, секреты из Vault |
| Обновился модуль — сломался прод | `source` без версии | пиннинг `ref=` / `version` |

## Best Practices

* **Remote state с блокировкой и версионированием** — с первого дня.
* **Маленькие state** по окружению и слою.
* **Модули с зафиксированными версиями**, `for_each` вместо `count`.
* **`plan` в CI на каждый MR**, `apply` только сохранённого плана и после ревью.
* **`prevent_destroy`** на базах и хранилищах.
* **Никаких правок руками** в том, чем управляет Terraform.
