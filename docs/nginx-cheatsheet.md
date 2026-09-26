# Nginx: шпаргалка

Самое частое при работе с Nginx: проверка, reload, reverse proxy, TLS, разбор ошибок.

> Теория — [Nginx](nginx.md).

## Топ-20

| # | Категория | Команда / директива | Что делает |
|---|---|---|---|
| 1 | проверка | `nginx -t` | проверить синтаксис конфига |
| 2 | проверка | `nginx -T` | вывести итоговый конфиг со всеми include |
| 3 | управление | `systemctl reload nginx` | применить конфиг без обрыва соединений |
| 4 | управление | `systemctl status nginx` | статус и последние ошибки |
| 5 | логи | `tail -f /var/log/nginx/error.log` | ошибки в реальном времени |
| 6 | логи | `tail -f /var/log/nginx/access.log` | запросы в реальном времени |
| 7 | проверка | `curl -I -H "Host: example.com" http://127.0.0.1` | проверить конкретный server_name локально |
| 8 | сайт | `ln -s /etc/nginx/sites-available/app /etc/nginx/sites-enabled/` | включить сайт (Debian/Ubuntu) |
| 9 | конфиг | `listen 80; server_name example.com;` | на какой порт и домен отвечать |
| 10 | статика | `root /var/www/html; try_files $uri $uri/ =404;` | раздать файлы |
| 11 | статика | `try_files $uri /index.html;` | роутинг SPA |
| 12 | proxy | `proxy_pass http://127.0.0.1:8000;` | передать запрос приложению |
| 13 | proxy | `proxy_set_header X-Real-IP $remote_addr;` | передать IP клиента |
| 14 | balancing | `upstream backend { server a:80; server b:80; }` | группа бэкендов |
| 15 | balancing | `least_conn;` | туда, где меньше соединений |
| 16 | TLS | `listen 443 ssl; ssl_certificate fullchain.pem;` | HTTPS |
| 17 | TLS | `return 301 https://$host$request_uri;` | редирект на HTTPS |
| 18 | TLS | `certbot --nginx -d example.com` | получить сертификат Let's Encrypt |
| 19 | лимиты | `client_max_body_size 20m;` | размер загрузки (иначе 413) |
| 20 | лимиты | `limit_req zone=api burst=20 nodelay;` | rate limiting |

## Минимальный reverse proxy

```nginx
server {
    listen 80;
    server_name app.example.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /health {
        access_log off;
        return 200 "ok\n";
    }
}
```

## Что означает ошибка

| Код | Первое, что проверить |
|---|---|
| 502 | жив ли бэкенд и тот ли порт: `curl localhost:8000`, `ss -tulpn` |
| 504 | долгий запрос в приложении, `proxy_read_timeout` |
| 413 | `client_max_body_size` |
| 403 | права на файлы, `allow/deny` |
| 404 | `root` / `alias`, `try_files` |
