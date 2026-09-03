# Ansible: команды с подробным описанием

Основные команды Ansible: ad-hoc, playbook, инвентарь, диагностика и отладка.

> Теория (концепции, инвентарь, playbook, модули) — [Ansible (теория)](ansible.md).
> Мини-шпаргалка — [Ansible: шпаргалка топ-20](ansible-cheatsheet.md).

## Проверка установки

```
$ ansible --version
ansible [core 2.15.x]
  config file = None
  configured module search path = ...
  python version = 3.11.x
```

`ansible --version` — версия Ansible, путь к конфиг-файлу, версия Python. Разные `ansible` и `ansible-core` — пакеты (полный набор vs ядро).

## Инвентарь (inventory)

### ansible-inventory
```bash
# Показать весь инвентарь в формате списка
ansible-inventory -i hosts.ini --list

# Показать в древовидном виде
ansible-inventory -i hosts.ini --graph

# Только хост web1
ansible-inventory -i hosts.ini --host web1
```

### ansible all --list-hosts
```bash
ansible all -i hosts.ini --list-hosts   # какие хосты попали в группу all
```

## Проверка подключения к хостам

### ansible ping
```bash
# Пинг всех хостов (проверка SSH + Python)
ansible all -i hosts.ini -m ping

# Пинг только группы webservers
ansible webservers -i hosts.ini -m ping

# С заданным пользователем и sudo
ansible all -i hosts.ini -u ubuntu --become -m ping
```

> `-m ping` — не ICMP! Проверяет, что Ansible может подключиться по SSH и выполнить Python. Результат `pong` = OK.

## Ad-hoc команды (разовые действия без плейбука)

Формат: `ansible <хосты> -m <модуль> -a "<аргументы>"`

```bash
# Выполнить команду (модуль command)
ansible all -m command -a "uptime"

# Модуль shell — с пайпами/переменными (в отличие от command)
ansible all -m shell -a "cat /etc/os-release | grep PRETTY"

# Установить пакет (apt) на Ubuntu
ansible all -i hosts.ini --become -m apt -a "name=nginx state=present"

# Запустить сервис
ansible all -i hosts.ini --become -m service -a "name=nginx state=started"

# Скопировать файл
ansible all -i hosts.ini -m copy -a "src=./app.conf dest=/etc/app.conf mode=0644"

# Создать пользователя
ansible all -i hosts.ini --become -m user -a "name=deploy shell=/bin/bash"

# Перезагрузить все хосты (кикбокс паролей нет — по SSH)
ansible all -m shell -a "reboot"
```

## Работа с playbook

### ansible-playbook
```bash
# Запустить плейбук по умолчанию (./hosts)
ansible-playbook playbook.yml

# С конкретным инвентарём
ansible-playbook -i hosts.ini playbook.yml

# Судо-права (become)
ansible-playbook -i hosts.ini --become playbook.yml

# Только проверить, что изменится (dry-run)
ansible-playbook -i hosts.ini --check playbook.yml

# Показывать подробный вывод (verbosity)
ansible-playbook -i hosts.ini -v playbook.yml    # -vvv / -vvvv ещё подробнее

# Прогнать одну задачу по тегу
ansible-playbook -i hosts.ini --tags "install" playbook.yml

# Пропустить тег
ansible-playbook -i hosts.ini --skip-tags "restart" playbook.yml

# Запустить со своей стартовой задачи (по имени)
ansible-playbook -i hosts.ini --start-at-task "Запустить nginx" playbook.yml

# Передать переменную на лету
ansible-playbook -i hosts.ini -e "app_port=9090" playbook.yml
```

### Синтаксис-проверка
```bash
ansible-playbook -i hosts.ini --syntax-check playbook.yml   # проверить YAML/структуру
```

## Диагностика и отладка

### --list-tasks / --list-hosts
```bash
ansible-playbook playbook.yml --list-tasks   # показать список задач без запуска
ansible-playbook playbook.yml --list-hosts   # на какие хосты будет применяться
```

### Модуль debug
В плейбуке вывод переменных:
```yaml
- name: Показать переменную
  debug:
    msg: "Приложение слушает порт {{ app_port }}"
```

### Сводка PLAY RECAP
В конце каждого прогона:
```
PLAY RECAP *************************************
web1 : ok=4    changed=1    unreachable=0    failed=0
```
* `ok` — задачи выполнены (без изменений)
* `changed` — состояние изменилось
* `unreachable` — не удалось подключиться
* `failed` — задачи упали

## Разбор типичной ошибки

```
fatal: [web1]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```
Причины: нет SSH-доступа, неверный пользователь (`-u`), нет Python на хосте. Проверь `ssh web1` вручную, затем `ansible web1 -m ping`.

## Кэш фактов (gather facts)

По умолчанию Ansible собирает факты о хосте (`gather_facts: true`) — это данные о системе, доступные как переменные:
```yaml
- name: Показать факты ОС
  debug:
    var: ansible_os_family
```

Факты полезны для условной логики (`when: ansible_os_family == "Debian"`), но замедляют прогон — можно отключить `gather_facts: false`, если не нужны.

> Полный справочник конструкций и примеров — [Ansible (теория)](ansible.md).
