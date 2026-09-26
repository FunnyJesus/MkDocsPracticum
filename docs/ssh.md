# SSH глубже: config, бастион, туннели, agent

SSH — основной способ попасть на сервер. Кроме `ssh user@host` в нём есть инструменты, которые экономят кучу времени: конфиг с короткими именами, прыжки через бастион, проброс портов к закрытым базам.

> Базовое подключение и ключи — [Linux](linux.md). Hardening сервера (`PermitRootLogin`, fail2ban) — [Безопасность](security.md).

## Ключи: коротко

```bash
ssh-keygen -t ed25519 -C "alex@laptop"      # создать пару ключей (ed25519 — современный стандарт)
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host   # положить публичный ключ на сервер
ssh -i ~/.ssh/work_key user@host            # подключиться конкретным ключом
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519  # права: иначе SSH откажется использовать ключ
```

* `id_ed25519` — **приватный** ключ, никому не отдавать и не коммитить.
* `id_ed25519.pub` — **публичный**, кладётся на сервер в `~/.ssh/authorized_keys`.
* `~/.ssh/known_hosts` — отпечатки серверов, к которым ты уже подключался (защита от подмены).

## ~/.ssh/config — короткие имена

Вместо `ssh -i ~/.ssh/work_key -p 2222 deploy@10.20.30.40` писать `ssh web1`:

```sshconfig
# ~/.ssh/config

# общие настройки для всех хостов
Host *
    ServerAliveInterval 60        # слать keep-alive, чтобы соединение не рвалось
    AddKeysToAgent yes
    IdentitiesOnly yes            # пробовать только указанный ключ, а не все подряд

Host web1
    HostName 10.20.30.40
    User deploy
    Port 2222
    IdentityFile ~/.ssh/work_key

# шаблон: ssh prod-db, ssh prod-api …
Host prod-*
    User ubuntu
    IdentityFile ~/.ssh/prod_key

Host github.com
    IdentityFile ~/.ssh/github_key
```

Имена из конфига работают везде: `scp file web1:/tmp/`, `rsync -a dir/ web1:/srv/`, в Ansible inventory, в VS Code Remote-SSH.

## Бастион (jump host)

В нормальной инфраструктуре серверы в приватной сети не доступны из интернета напрямую. Вход — через один **бастион** (jump host), доступ к которому строго ограничен и логируется.

```
ноутбук ──ssh──► bastion (публичный IP) ──ssh──► app-1 (10.0.1.15, приватный)
```

```bash
ssh -J user@bastion.example.com user@10.0.1.15      # одна команда, два прыжка
```

То же через конфиг:

```sshconfig
Host bastion
    HostName bastion.example.com
    User alex

Host 10.0.1.*
    User ubuntu
    ProxyJump bastion
```

```bash
ssh 10.0.1.15        # автоматически пройдёт через bastion
```

> Ключ при этом **не копируется на бастион** — это главное преимущество `ProxyJump` перед «зайти на бастион и оттуда ssh дальше».

## Туннели (port forwarding)

### Local forward `-L` — достучаться до закрытого сервиса

База в приватной сети, доступна только с app-сервера. Хочу подключиться к ней DBeaver-ом с ноутбука:

```bash
ssh -L 5433:db.internal:5432 bastion
#       │    │           │
#       │    │           └─ порт на стороне назначения
#       │    └─ куда подключаться (с точки зрения bastion)
#       └─ локальный порт на ноутбуке

psql -h localhost -p 5433 -U app     # на ноутбуке — попадаем в db.internal:5432
```

```bash
ssh -N -f -L 5433:db.internal:5432 bastion   # -N без shell, -f в фоне
```

То же, что делает `kubectl port-forward` для подов.

### Remote forward `-R` — показать локальное наружу

```bash
ssh -R 8080:localhost:3000 server
# на server порт 8080 ведёт на localhost:3000 твоего ноутбука
```

### Dynamic forward `-D` — SOCKS-прокси

```bash
ssh -D 1080 bastion
# в браузере указать SOCKS5 localhost:1080 — весь трафик пойдёт через bastion
# (открыть внутренние веб-интерфейсы: Grafana, Kibana)
```

## ssh-agent

Agent держит расшифрованные ключи в памяти — пароль от ключа вводится один раз.

```bash
eval "$(ssh-agent -s)"            # запустить (обычно уже запущен)
ssh-add ~/.ssh/id_ed25519         # добавить ключ
ssh-add -l                        # список ключей в агенте
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # macOS: запомнить пароль в Keychain
```

**Agent forwarding** (`ssh -A`) позволяет использовать твой ключ на удалённом сервере (например, `git pull` с сервера). Но root на этом сервере тоже сможет использовать твой агент — **на недоверенные хосты не включать**. Для прыжков используй `ProxyJump`, а не `-A`.

## Полезные команды

```bash
ssh web1 'df -h; uptime'          # выполнить команду и выйти
ssh web1 'bash -s' < script.sh    # выполнить локальный скрипт на удалённом хосте
scp file.txt web1:/tmp/           # скопировать файл
rsync -avz --progress dir/ web1:/srv/dir/   # синхронизировать папку (только изменения)
ssh -v web1                       # отладка подключения (-vvv — максимум)
ssh-keygen -R 10.20.30.40         # удалить старый отпечаток из known_hosts
ssh-keyscan github.com >> ~/.ssh/known_hosts   # добавить отпечаток (в CI)
```

Зависшая сессия: нажать по очереди `Enter`, `~`, `.` — SSH закроет соединение.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `Permission denied (publickey)` | ключ не тот, не лежит в `authorized_keys` или неверные права | `ssh -v`, проверить `IdentityFile`, `chmod 600` ключа и `700` на `~/.ssh` |
| `UNPROTECTED PRIVATE KEY FILE!` | права на ключ слишком открыты | `chmod 600 ~/.ssh/key` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED!` | сервер пересоздан с тем же IP (или атака) | убедиться, что сервер переустанавливали, затем `ssh-keygen -R host` |
| `Too many authentication failures` | агент перебрал все ключи до нужного | `IdentitiesOnly yes` + конкретный `IdentityFile` |
| Сессия рвётся через несколько минут простоя | NAT/firewall закрывает неактивное соединение | `ServerAliveInterval 60` |
| CI: `Host key verification failed` | в чистом раннере пустой `known_hosts` | `ssh-keyscan host >> ~/.ssh/known_hosts` |

## Best Practices

* **ed25519 и пароль на ключ** + ssh-agent, чтобы не вводить его каждый раз.
* **Отдельные ключи** для работы, личного GitHub и CI.
* **`~/.ssh/config` вместо длинных команд** — меньше ошибок, работает во всех инструментах.
* **ProxyJump вместо agent forwarding.**
* **Туннель вместо открытия порта базы в интернет.**
