# Ansible (теория)

Ansible — это система автоматизации управления конфигурацией (SCM, Configuration Management) по подходу IaC. Позволяет описывать желаемое состояние серверов декларативно и приводить их к нему без ручной работы.

> В отличие от Terraform (создаёт/удаляет инфраструктуру в облаке), Ansible в основном **настраивает уже существующие серверы**: ставит ПО, правит конфиги, запускает сервисы. Общее у них — декларативное описание «как должно быть».

## Ключевые особенности

* **Agentless (без агентов)** — на целевых машинах не нужен установленный агент, работает по SSH.
* **Push-модель** — управляющий узел (control node) сам подключается к серверам и выполняет задачи.
* **Идемпотентность** — повторный запуск не ломает систему: изменения применяются только если текущее состояние отличается от желаемого.
* **Декларативность** — описываем «что», а не «как» (порядок шагов сам определяет).

## Основные компоненты

### Control node (управляющий узел)
Тот, с кого запускаются команды `ansible` / `ansible-playbook`. Обычно это машина разработчика или CI.

### Inventory (инвентарь)
Список управляемых хостов. По умолчанию — файл `/etc/ansible/hosts`, но чаще задаётся свой через `-i`.

```ini
# inventory.ini
[webservers]
web1.example.com
web2.example.com

[dbservers]
db1.example.com ansible_user=ubuntu
```

Также бывает YAML-формат инвентаря и динамический (из облака).

### Playbook
Основной файл автоматизации (YAML). Описывает набор **plays** (пьес) — «на каких хостах что сделать».

```yaml
# playbook.yml
---
- name: Развернуть nginx
  hosts: webservers
  become: true            # выполнять с правами sudo
  tasks:
    - name: Установить nginx
      apt:
        name: nginx
        state: present
    - name: Запустить nginx
      service:
        name: nginx
        state: started
        enabled: true
```

### Модули
Готовые «кирпичики» действий Ansible: `apt`, `yum`, `copy`, `template`, `service`, `file`, `user`, `command` и сотни других. Модуль — атомарная операция, у которой есть параметры.

```yaml
- name: Скопировать конфиг
  copy:
    src: ./nginx.conf
    dest: /etc/nginx/nginx.conf
    mode: "0644"
```

### Tasks (задачи)
Отдельные шаги внутри play. Каждая задача вызывает один модуль.

### Plays
Play — это блок «hosts + tasks» (а иногда `vars`, `roles`). В одном playbook может быть несколько plays.

### Roles (роли)
Способ переиспользования: структурированный набор плейбуков, tasks, handlers, templates, vars. Удобно для библиотеки стандартных конфигов.

```
roles/
└── nginx/
    ├── tasks/main.yml
    ├── handlers/main.yml
    ├── templates/
    └── vars/main.yml
```

### Handlers (обработчики)
Задачи, которые запускаются **только** когда их уведомили (`notify`) и только если что-то реально изменилось.

```yaml
- name: Изменить конфиг
  template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
  notify: restart nginx     # уведомить хендлер

handlers:
  - name: restart nginx
    service:
      name: nginx
      state: restarted
```

### Variables (переменные)
Данные, используемые в плейбуках. Приоритет (от высшего к низшему): `--extra-vars` > playbook vars > inventory > defaults.

```yaml
vars:
  app_port: 8080
  domain: "example.com"
```

### Templates (шаблоны)
Файлы с переменными — движок **Jinja2**. Расширение `.j2`.

```jinja2
server {
    listen {{ app_port }};
    server_name {{ domain }};
}
```

## Как это работает (поток)

1. Контрольная нода читает inventory → знает, куда подключаться.
2. Читает playbook → понимает какие модули/задачи применить.
3. По SSH подключается к каждому хосту.
4. Выполняет задачи идемпотентно.
5. В конце выдаёт сводку: `ok`, `changed`, `failed`, `skipped`.

```
PLAY RECAP ************************************************************
web1.example.com : ok=3    changed=1    unreachable=0    failed=0
```

## Ansible vs Terraform (кратко)

| Характеристика | Ansible | Terraform |
|---|---|---|
| Основная цель | управление конфигурацией серверов | создание инфраструктуры (провайдеры) |
| Целевые объекты | серверы, ПО, конфиги | ВМ, сети, балансировщики в облаке |
| Протокол | SSH (agentless) | API облака (провайдер) |
| State-файл | нет | `terraform.tfstate` |
| Порядок | идемпотентно по модулям | параллельно по зависимостям |

> Связка «Terraform создаёт ВМ → Ansible настраивает на них ПО» — классический паттерн.

> Команды Ansible — на странице [Ansible: команды с подробным описанием](ansible-commands.md).
> Мини-шпаргалка — [Ansible: шпаргалка топ-20](ansible-cheatsheet.md).
