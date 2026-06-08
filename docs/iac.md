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
