# IaC: шпаргалка топ-20 команд Terraform

Самое частое в работе с Terraform. Быстрый доступ к командам и рабочему циклу.

> Подробно по каждой команде: [IaC: команды Terraform](iac-commands.md). Теория — [IaC (теория)](iac.md).

## Топ-20 команд

| # | Команда | Что делает |
|---|---|---|
| 1 | `terraform --version` | версия CLI и провайдеров |
| 2 | `terraform --help` | справка |
| 3 | `terraform init` | инициализация провайдеров и модулей |
| 4 | `terraform init -upgrade` | init с обновлением версий в рамках ограничений |
| 5 | `terraform validate` | проверка синтаксиса и логики `*.tf` |
| 6 | `terraform fmt` | автоформатирование `*.tf` |
| 7 | `terraform fmt -recursive` | форматирование во всех подкаталогах |
| 8 | `terraform plan` | показать план изменений (перед apply) |
| 9 | `terraform plan -destroy` | показать, что удалится при destroy |
| 10 | `terraform plan -replace=<ресурс>` | план с пересозданием конкретного ресурса |
| 11 | `terraform apply` | применить изменения (создать/изменить ресурсы) |
| 12 | `terraform apply -replace=<ресурс>` | применить с пересозданием ресурса |
| 13 | `terraform show` | вывод state в консоль |
| 14 | `terraform state list` | список развёрнутых ресурсов |
| 15 | `terraform state show <ресурс>` | детали конкретного ресурса |
| 16 | `terraform state rm <ресурс>` | убрать ресурс из state (без удаления в облаке) |
| 17 | `terraform state mv <a> <b>` | переименовать/переместить ресурс в state |
| 18 | `terraform output` | вывод значения output-переменных |
| 19 | `terraform output <имя>` | вывод конкретной output-переменной |
| 20 | `terraform destroy` | удалить все ресурсы конфигурации ⚠️ необратимо |

## Рабочий цикл (главное)

```bash
terraform init      # 1. инициализация провайдеров и модулей
terraform fmt       # 2. форматирование кода (опционально)
terraform validate  # 3. проверка синтаксиса
terraform plan      # 4. показать план изменений (ОБЯЗАТЕЛЬНО перед apply)
terraform apply     # 5. применить изменения
terraform show      # 6. посмотреть текущее состояние
terraform destroy   # 7. удалить всё, когда не нужно ⚠️
```

> **Запомни правило**: `plan` → `apply`. Сначала смотри, что изменится, потом применяй.

## Важные предупреждения

- `terraform destroy` **необратим** — перед ним делай `terraform plan -destroy` и backup важных данных.
- `terraform.tfstate` **не коммить в git** (чувствительные данные) → используй удалённый backend (S3 / Object Storage / GitLab) и `.gitignore`.
- Некоторые изменения параметров могут **пересоздать ресурс** — смотри `plan` перед `apply`.
- `terraform refresh` устарел: теперь обновление state автоматически входит в `plan`/`apply`.

## Структура state (backend)

```hcl
terraform {
  backend "s3" {
    bucket = "my-tf-state"
    key    = "prod/terraform.tfstate"
    region = "ru-central1"
  }
}
```

> Все команды с флагами и примерами — на странице [IaC: команды Terraform](iac-commands.md).
