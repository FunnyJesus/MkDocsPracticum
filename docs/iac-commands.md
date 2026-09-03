# IaC: команды Terraform с подробным описанием

Основные команды Terraform. Теория (блоки, структура) — на странице [IaC (теория)](iac.md).

> Мини-шпаргалка «топ-20»: [IaC: шпаргалка топ-20 команд](iac-cheatsheet.md).

## Основные команды terraform

### terraform --help

* `terraform --help` - вывод информационой справки 

---------
### terraform --version

* `terraform --version` - выводит версию terraform и провайдера

---------

### terraform init
* `terraform init` - инициализация провайдера без обновлении версии
* `terraform init -upgrade` - инициализация провайдера с обновление версии в рамках ограничейний 

---------

### terraform validate
* `terrafom validate` - валидация *.tf файлов

---------

### terraform plan
* `terraform plan` - предварительный просмотр плана. Выполнять перед `terraform apply`

---------

### terraform apply
* `terraform apply` - применение всех натроек и инициализация процесса развертывания 
```
yandex_compute_instance.vm-1: Creating...
yandex_compute_instance.vm-1: Still creating... [10s elapsed]
yandex_compute_instance.vm-1: Still creating... [20s elapsed]
yandex_compute_instance.vm-1: Still creating... [30s elapsed]
yandex_compute_instance.vm-1: Still creating... [40s elapsed]
yandex_compute_instance.vm-1: Creation complete after 43s [id=fhmuo...]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

---------

### terraform show
* `terraform show` - вывод state в консоль 

---------

### terraform state list
* `terraform state list` - вывод список развернутых ресурсов

---------


### terraform fmt
* `terraform fmt` - автоматическое форматирование *.tf файлов (отступы, выравнивание)
* `terraform fmt -recursive` - форматирование всех файлов в подкаталогах

> Единообразный стиль кода помогает ревью и читаемости. Плюс не копятся лишние диффы в ревью.

---

### terraform destroy
* `terraform destroy` - удаление всех ресурсов, описанных в конфигурации (обратная операция apply)

```
$ terraform destroy
yandex_compute_instance.vm-1: Destroying... [id=fhmuo...]
yandex_compute_instance.vm-1: Destruction complete after 5s

Destroy complete! Resources: 1 destroyed.
```

> Перед destroy полезно сделать `terraform plan -destroy`, чтобы посмотреть, что удалится. Удаление необратимо — для важных данных делают backup.

---

### terraform output
* `terraform output` - вывод значений output-переменных из state
* `terraform output <имя>` - вывод конкретной переменной

```
$ terraform output
vm_ip = "51.250.11.22"

$ terraform output vm_ip
"51.250.11.22"
```

---

### terraform state (состояние)
* `terraform state` - работа с файлом состояния (state): просмотр, перемещение, удаление ресурсов из state

```
$ terraform state list                          # список ресурсов
$ terraform state show <адрес_ресурса>          # детали конкретного ресурса
$ terraform state rm <адрес_ресурса>            # убрать ресурс из state (не удаляя в облаке)
$ terraform state mv <откуда> <куда>            # переименовать/переместить ресурс в state
```

> `state` — файл `terraform.tfstate`, в котором Terraform хранит реальное состояние инфраструктуры. На проекте его хранят в удалённом backend (S3, Yandex Object Storage, GitLab) — это совместный доступ и защита от потери.

```
terraform {
  backend "s3" {
    bucket = "my-tf-state"
    key    = "prod/terraform.tfstate"
    region = "ru-central1"
  }
}
```

> Не коммить `terraform.tfstate` в git — он может содержать чувствительные данные. Используй `.gitignore` и удалённый backend.

---

### terraform refresh
* `terraform refresh` - обновить state в соответствии с реальным состоянием ресурсов (без изменения инфраструктуры)

> Сейчас `refresh` автоматически выполняется внутри `plan` и `apply`, но команда полезна для синхронизации, если инфраструктуру меняли вручную.

---

### terraform taint / untaint
* `terraform taint <ресурс>` - пометить ресурс как «испорченный», чтобы он был пересоздан при следующем apply (устаревшая — в новых версиях используют `-replace`)

```
$ terraform apply -replace=yandex_compute_instance.vm-1   # пересоздать конкретный ресурс
$ terraform plan -replace=yandex_compute_instance.vm-1    # посмотреть, что изменится
```

---

### Рабочий цикл Terraform (шпаргалка)

```
terraform init      # инициализация провайдеров и модулей
terraform fmt       # форматирование кода (опционально)
terraform validate  # проверка синтаксиса и логики
terraform plan      # показать план изменений (перед apply)
terraform apply     # применить изменения (создать/изменить ресурсы)
terraform show      # посмотреть текущее состояние
terraform destroy   # удалить всё (когда не нужно)
```
