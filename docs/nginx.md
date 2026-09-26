# Nginx

> Шпаргалка — [Nginx: шпаргалка](nginx-cheatsheet.md). Балансировка в Compose — [Load balancing](load-balancing.md). Ingress в Kubernetes — [K8s LoadBalancer и Ingress](k8s-loadbalancer.md).

**Nginx** — веб-сервер и reverse proxy. В DevOps он встречается повсюду: стоит перед приложениями, раздаёт статику, терминирует TLS, балансирует нагрузку. Самый популярный Ingress-контроллер в Kubernetes — тоже Nginx.

## Роли Nginx

| Роль | Что делает | Пример |
|---|---|---|
| **Веб-сервер** | отдаёт статические файлы | собранный фронтенд (React), этот сайт MkDocs |
| **Reverse proxy** | принимает запрос и передаёт приложению | Nginx :80 → Python/Node :8000 |
| **Балансировщик** | распределяет запросы между копиями | 3 экземпляра API |
| **TLS-терминация** | принимает HTTPS, дальше идёт HTTP | сертификат только на Nginx, не в каждом сервисе |
| **Кеш / сжатие / лимиты** | gzip, кеш ответов, rate limiting | защита API от перебора |

**Reverse proxy** vs **forward proxy**: forward — стоит перед **клиентами** (корпоративный прокси в интернет), reverse — перед **серверами** (клиент не знает, какой бэкенд ответил).

## Установка и управление

```bash
sudo apt install nginx
sudo systemctl enable --now nginx
sudo nginx -t                     # проверить конфиг — ВСЕГДА перед reload
sudo systemctl reload nginx       # применить конфиг без обрыва соединений
sudo nginx -T                     # показать итоговый конфиг со всеми include
curl -I http://localhost          # проверить ответ
```

```bash
docker run -d -p 8080:80 -v $(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro nginx:1.27
```

## Где лежат файлы

| Путь | Что там |
|---|---|
| `/etc/nginx/nginx.conf` | главный конфиг |
| `/etc/nginx/conf.d/*.conf` | конфиги сайтов (RHEL, официальный Docker-образ) |
| `/etc/nginx/sites-available/` | конфиги сайтов (Debian/Ubuntu) |
| `/etc/nginx/sites-enabled/` | симлинки на включённые сайты |
| `/var/log/nginx/access.log` | журнал запросов |
| `/var/log/nginx/error.log` | ошибки — **первое место при проблемах** |
| `/usr/share/nginx/html` или `/var/www/html` | статика по умолчанию |

```bash
# Debian/Ubuntu: включить сайт
sudo ln -s /etc/nginx/sites-available/myapp /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

## Структура конфига

Конфиг — вложенные **контексты** (блоки в `{}`) и **директивы** (строки с `;` в конце):

```nginx
user nginx;
worker_processes auto;            # по числу ядер

events {
    worker_connections 1024;      # соединений на один worker
}

http {                            # всё про HTTP
    include       mime.types;
    sendfile      on;
    gzip          on;

    server {                      # один виртуальный хост (сайт)
        listen      80;
        server_name example.com;

        location / {              # правило для URL
            root /var/www/html;
        }
    }
}
```

`server_name` определяет, какой `server` обработает запрос (по заголовку `Host`). Если ни один не подошёл — отработает `default_server` (или первый в списке).

## Статический сайт

```nginx
server {
    listen 80;
    server_name docs.example.com;
    root /var/www/docs;
    index index.html;

    location / {
        try_files $uri $uri/ =404;         # файл → папка с index.html → 404
    }

    # для SPA (React/Vue): все неизвестные пути отдают index.html
    # try_files $uri $uri/ /index.html;

    location ~* \.(css|js|png|jpg|svg|woff2)$ {
        expires 30d;                       # кешировать статику в браузере
        access_log off;
    }
}
```

## Reverse proxy

```nginx
server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://127.0.0.1:8000;

        # передать приложению данные об оригинальном запросе
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
    }
}
```

> Без `X-Real-IP` / `X-Forwarded-For` приложение видит IP самого Nginx вместо IP клиента.

### Слеш в proxy_pass — частая ловушка

```nginx
location /api/ {
    proxy_pass http://backend;      # /api/users → http://backend/api/users (путь как есть)
}

location /api/ {
    proxy_pass http://backend/;     # /api/users → http://backend/users (префикс /api/ отрезан)
}
```

### WebSocket

```nginx
location /ws/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

## location: порядок выбора

| Синтаксис | Тип | Приоритет |
|---|---|---|
| `location = /health` | точное совпадение | 1 — самый высокий |
| `location ^~ /static/` | префикс, regex не проверяются | 2 |
| `location ~ \.php$` | regex с учётом регистра | 3 — первый подходящий по порядку в файле |
| `location ~* \.(jpg|png)$` | regex без учёта регистра | 3 |
| `location /api/` | обычный префикс | 4 — самый длинный из подходящих |
| `location /` | всё остальное | последний |

## Балансировка нагрузки

```nginx
upstream backend {
    # алгоритм (по умолчанию round robin):
    # least_conn;            # туда, где меньше активных соединений
    # ip_hash;               # один клиент → всегда один сервер (липкие сессии)

    server 10.0.0.11:8000 weight=3;          # получит в 3 раза больше запросов
    server 10.0.0.12:8000;
    server 10.0.0.13:8000 max_fails=3 fail_timeout=30s;   # исключить при ошибках
    server 10.0.0.14:8000 backup;            # только если остальные недоступны

    keepalive 32;            # держать соединения к бэкендам открытыми
}

server {
    listen 80;
    location / {
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";      # нужно для keepalive к upstream
        proxy_next_upstream error timeout http_502;   # повторить на другом сервере
    }
}
```

## HTTPS и Let's Encrypt

```nginx
server {
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;        # весь HTTP → HTTPS
}

server {
    listen 443 ssl;
    http2 on;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;   # HSTS

    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
```

Бесплатный сертификат от Let's Encrypt через **certbot**:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d example.com -d www.example.com   # получит и пропишет в конфиг
sudo certbot renew --dry-run      # проверить автопродление (сертификат живёт 90 дней)
systemctl list-timers | grep certbot                   # таймер продления
```

> `fullchain.pem`, а не `cert.pem` — иначе часть клиентов не сможет проверить цепочку сертификатов. В Kubernetes то же делает **cert-manager**.

## Лимиты и защита

```nginx
http {
    # зона: ключ — IP клиента, 10 МБ памяти, 10 запросов в секунду
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        client_max_body_size 20m;          # максимальный размер загрузки (по умолчанию 1m!)
        server_tokens off;                 # не показывать версию nginx

        location /api/ {
            limit_req zone=api burst=20 nodelay;
            proxy_pass http://backend;
        }

        location /admin/ {
            allow 10.0.0.0/8;
            deny  all;
            proxy_pass http://backend;
        }
    }
}
```

## Логи

```nginx
log_format main '$remote_addr - [$time_local] "$request" $status $body_bytes_sent '
                '"$http_user_agent" rt=$request_time urt=$upstream_response_time';
access_log /var/log/nginx/access.log main;
```

`$request_time` — полное время запроса, `$upstream_response_time` — сколько отвечал бэкенд. Если первое сильно больше второго — медленный клиент или сеть, а не приложение.

```bash
tail -f /var/log/nginx/error.log
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn   # коды ответов
```

Больше однострочников — [Обработка текста](text-processing.md).

## Коды ошибок от Nginx

| Код | Что значит | Где искать |
|---|---|---|
| **502 Bad Gateway** | бэкенд не отвечает / отказал в соединении | приложение упало? правильный порт в `proxy_pass`? `error.log`: `connect() failed (111: Connection refused)` |
| **504 Gateway Timeout** | бэкенд не ответил за `proxy_read_timeout` | медленный запрос в приложении/базе |
| **413 Request Entity Too Large** | тело запроса больше `client_max_body_size` | увеличить лимит |
| **403 Forbidden** | нет прав на файлы или `deny` | права на `root`, пользователь nginx, SELinux |
| **404 Not Found** | файла нет по `root` + URI | проверить `root` / `alias`, `try_files` |

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| После reload nginx не поднялся | синтаксическая ошибка в конфиге | всегда `nginx -t && systemctl reload nginx` |
| Приложение видит IP `127.0.0.1` вместо клиента | не переданы заголовки | `X-Real-IP`, `X-Forwarded-For` |
| Путь к API «задваивается» или теряется | слеш в конце `proxy_pass` | см. раздел про слеш выше |
| Изменения конфига не применились | правили `sites-available`, но нет симлинка в `sites-enabled` | `ln -s`, `nginx -T` — посмотреть реальный конфиг |
| Браузер ругается на сертификат на части устройств | указан `cert.pem` без цепочки | `fullchain.pem` |
| Загрузка файла падает с 413 | лимит 1 МБ по умолчанию | `client_max_body_size` |

## Best Practices

* **`nginx -t` перед каждым reload**, `reload` вместо `restart`.
* **Один сайт — один файл** в `conf.d/` или `sites-available/`.
* **Всегда передавай `X-Forwarded-*`** заголовки в приложение.
* **HTTPS по умолчанию**, редирект с HTTP, автопродление certbot.
* **Логи с `$request_time`** — сразу видно медленные запросы.
* **Конфиг — в git и через Ansible**, а не правкой на сервере.
