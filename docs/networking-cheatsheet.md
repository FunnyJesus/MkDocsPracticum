# Сети: шпаргалка топ-20 команд

Быстрая диагностика сети, DNS, HTTP и TLS.

> Теория — [Сети](networking.md).

## Топ-20 команд

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | доступность | `ping <host>` | проверить доступность хоста и задержку |
| 2 | маршрут | `traceroute <host>` | путь пакета до хоста по узлам |
| 3 | порт | `nc -zv <host> <port>` | проверить, открыт ли TCP-порт |
| 4 | порты хоста | `ss -tlnp` | какие TCP-порты слушаются и каким процессом |
| 5 | порты хоста (устар.) | `netstat -tlnp` | то же, старый инструмент |
| 6 | HTTP | `curl -v <url>` | полный HTTP-обмен: заголовки, статус |
| 7 | HTTP | `curl -I <url>` | только заголовки ответа (HEAD) |
| 8 | HTTP | `curl -o /dev/null -s -w '%{http_code} %{time_total}\n' <url>` | код ответа + время без тела |
| 9 | HTTP retry | `curl -sf <url> \|\| echo fail` | завершить с ошибкой на не-2xx (для скриптов/healthcheck) |
| 10 | DNS | `dig <host>` | A-запись домена |
| 11 | DNS | `dig +short <host>` | только IP, без служебной информации |
| 12 | DNS | `dig <host> MX` | запись конкретного типа |
| 13 | DNS (альт.) | `nslookup <host>` | альтернатива dig |
| 14 | DNS путь | `dig +trace <host>` | путь резолвинга от корневых серверов |
| 15 | TLS | `openssl s_client -connect host:443 -servername host` | проверить TLS-хендшейк и сертификат |
| 16 | TLS | `echo \| openssl s_client -connect host:443 2>/dev/null \| openssl x509 -noout -dates` | срок действия сертификата |
| 17 | firewall | `sudo ufw status` | текущие правила firewall |
| 18 | firewall | `sudo ufw allow 443/tcp` | открыть порт |
| 19 | iptables | `iptables -L -n -v` | правила фильтрации пакетов |
| 20 | трафик | `sudo tcpdump -i eth0 port 80` | перехват трафика на интерфейсе |

## Быстрая диагностика «сайт не открывается» (по уровням)

```bash
ping example.com              # L3: хост вообще доступен?
nc -zv example.com 443        # L4: порт открыт?
curl -v https://example.com   # L7: что отвечает приложение?
dig example.com                # DNS резолвится туда, куда нужно?
openssl s_client -connect example.com:443 -servername example.com  # сертификат в порядке?
```

## Docker/Compose DNS

```bash
docker exec <container> getent hosts <service>   # резолвится ли имя сервиса изнутри контейнера
docker exec <container> nslookup <service>
```

> Подробности DNS-резолвинга и proxy_pass в Docker-сетях — в [Сети в Docker Compose](compose-networks.md).
