# Ansible: шпаргалка топ-20 конструкций

Самое нужное для автоматизации конфигурации. Быстрые команды, ad-hoc и готовый шаблон playbook.

> Теория — [Ansible (теория)](ansible.md). Подробно по командам — [Ansible: команды](ansible-commands.md).

## Топ-20 ad-hoc команд

| # | Команда | Что делает |
|---|---|---|
| 1 | `ansible --version` | версия Ansible и Python |
| 2 | `ansible-inventory -i hosts.ini --list` | показать инвентарь |
| 3 | `ansible all -i hosts.ini --list-hosts` | какие хосты в группе all |
| 4 | `ansible all -i hosts.ini -m ping` | проверить SSH-подключение (не ICMP) |
| 5 | `ansible all -m command -a "uptime"` | выполнить команду |
| 6 | `ansible all -m shell -a "cmd \| grep x"` | команда с пайпами/переменными |
| 7 | `ansible all --become -m apt -a "name=nginx state=present"` | установить пакет (Ubuntu) |
| 8 | `ansible all --become -m yum -a "name=nginx state=present"` | установить пакет (RHEL) |
| 9 | `ansible all --become -m service -a "name=nginx state=started"` | запустить сервис |
| 10 | `ansible all -m copy -a "src=x dest=y mode=0644"` | скопировать файл |
| 11 | `ansible all --become -m user -a "name=deploy shell=/bin/bash"` | создать пользователя |
| 12 | `ansible-playbook -i hosts.ini playbook.yml` | запустить плейбук |
| 13 | `ansible-playbook --become playbook.yml` | запуск с sudo |
| 14 | `ansible-playbook --check playbook.yml` | dry-run (что изменится) |
| 15 | `ansible-playbook --syntax-check playbook.yml` | проверить синтаксис |
| 16 | `ansible-playbook -v / -vvv` | подробный вывод (отладка) |
| 17 | `ansible-playbook --tags "install" playbook.yml` | только задачи с тегом |
| 18 | `ansible-playbook -e "app_port=9090" playbook.yml` | передать переменную |
| 19 | `ansible-playbook --list-tasks playbook.yml` | показать список задач |
| 20 | `ansible-playbook --start-at-task "Запуск nginx"` | старт с конкретной задачи |

## Готовый шаблон playbook

```yaml
---
- name: Развернуть nginx
  hosts: webservers
  become: true
  vars:
    app_port: 8080
  tasks:
    - name: Установить nginx
      apt:
        name: nginx
        state: present

    - name: Скопировать конфиг из шаблона
      template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
      notify: restart nginx

    - name: Запустить nginx
      service:
        name: nginx
        state: started
        enabled: true

  handlers:
    - name: restart nginx
      service:
        name: nginx
        state: restarted
```

## Топ-10 самых частых модулей

| Модуль | Назначение |
|---|---|
| `apt` / `yum` | управление пакетами (Ubuntu/RHEL) |
| `service` / `systemd` | управление сервисами |
| `copy` | скопировать файл на хост |
| `template` | отрендерить файл из Jinja2-шаблона |
| `file` | создавать/удалять файлы и каталоги |
| `user` | управление пользователями |
| `command` / `shell` | выполнить команду |
| `lineinfile` | вставить/заменить строку в файле |
| `debug` | вывод переменных для отладки |
| `git` | клонировать репозиторий |

## Мини-памятка флагов

- `-m <модуль>` — модуль; `-a "<аргументы>"` — его параметры
- `-i <inventory>` — свой файл инвентаря
- `-u <user>` — пользователь SSH; `-k` — запросить пароль
- `--become` / `-b` — sudo; `--become-user=root`
- `--check` — не применять, только показать
- `-e "var=value"` — extra variables (высший приоритет)

> Все команды с примерами и разбором ошибок — на странице [Ansible: команды](ansible-commands.md).
