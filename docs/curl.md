# curl: главные флаги и приёмы

> Сети и HTTP — [Сети](networking.md), [Сети: шпаргалка](networking-cheatsheet.md). Разбор JSON-ответов — [Обработка текста](text-processing.md) (`jq`). То же из Python — [Python: requests](python-scripts.md).

**curl** — консольный клиент для HTTP(S) и десятков других протоколов. Для DevOps это основной инструмент, чтобы:

* проверить, что сервис отвечает (healthcheck, smoke-тест после деплоя);
* разобраться, **где** ломается запрос: DNS, TCP, TLS, балансировщик или приложение;
* дёрнуть API (GitHub, GitLab, Kubernetes, облако, Prometheus) из скрипта или CI;
* скачать бинарник или установочный скрипт.

`wget` удобнее только для простого скачивания и рекурсивной загрузки сайта. Всё остальное — curl.

```bash
curl --version           # версия и что умеет (протоколы, HTTP/2, HTTP/3)
curl --help all          # все флаги
man curl
```

## Топ-20 флагов

| # | Флаг | Что делает |
|---|---|---|
| 1 | `-s` / `-S` / `-sS` | тихий режим (без прогресс-бара) / но показывать ошибки / **оба — стандарт для скриптов** |
| 2 | `-v` | подробно: DNS, соединение, TLS, заголовки запроса (`>`) и ответа (`<`) |
| 3 | `-i` | показать заголовки ответа вместе с телом |
| 4 | `-I` | отправить `HEAD` — только заголовки |
| 5 | `-o file` / `-O` | сохранить тело в файл / в файл с именем из URL |
| 6 | `-L` | следовать редиректам (301/302) |
| 7 | `-f` | **ошибка (код 22) при HTTP 4xx/5xx** — без этого `500` считается успехом |
| 8 | `-w '...'` | вывести после запроса: код ответа, время, IP и т.д. |
| 9 | `-X METHOD` | метод: `POST`, `PUT`, `PATCH`, `DELETE` |
| 10 | `-H 'Name: value'` | добавить заголовок |
| 11 | `-d 'data'` | тело запроса (сам делает POST) |
| 12 | `--json '{...}'` | тело JSON + заголовки `Content-Type` и `Accept: application/json` (curl 7.82+) |
| 13 | `-F 'file=@path'` | multipart-форма, загрузка файла |
| 14 | `-u user:pass` | Basic-аутентификация |
| 15 | `--connect-timeout N` / `-m N` | таймаут на соединение / на весь запрос (секунды) |
| 16 | `--retry N` | повторить при временной ошибке |
| 17 | `-k` | **не проверять** TLS-сертификат (только для отладки!) |
| 18 | `--resolve host:port:ip` | подставить IP для имени без DNS и `/etc/hosts` |
| 19 | `-x proxy` | через прокси |
| 20 | `--unix-socket path` | запрос через UNIX-сокет (Docker API) |

## Чтение вывода -v

```bash
curl -v https://example.com/
```

```
*   Trying 93.184.215.14:443...                       ← * — служебная информация curl
* Connected to example.com (93.184.215.14) port 443
* TLS 1.3 connection using TLS_AES_256_GCM_SHA384
* Server certificate:
*  subject: CN=www.example.org
*  expire date: Jan 15 23:59:59 2027 GMT
*  issuer: C=US; O=DigiCert Inc; CN=DigiCert Global G3 TLS ECC SHA384 2020 CA1
*  SSL certificate verify ok.
> GET / HTTP/2                                         ← > — что отправили
> Host: example.com
> User-Agent: curl/8.7.1
> Accept: */*
>
< HTTP/2 200                                           ← < — что получили
< content-type: text/html
< content-length: 1256
<
<!doctype html>...                                     ← тело ответа
```

По `-v` видно, **на каком шаге** проблема:

| Где остановилось | Значит | Куда смотреть |
|---|---|---|
| `Could not resolve host` | DNS | `dig`, `/etc/resolv.conf` |
| висит на `Trying ...` | TCP не устанавливается: firewall, security group, сервис не слушает | `ss -tulpn`, правила firewall |
| `Connection refused` | хост доступен, но порт закрыт | процесс не запущен / слушает `127.0.0.1` |
| ошибка после `TLS handshake` | сертификат: истёк, не тот домен, нет цепочки | раздел TLS ниже |
| получили `< HTTP/... 502/503/504` | соединение есть, ошибка за балансировщиком | логи nginx/Ingress и приложения |

`--trace-ascii - --trace-time` — ещё подробнее, с временем каждой строки.

## Вывод для скриптов: -s, -S, -f, -o, -w

```bash
curl -sS https://api.example.com/health             # без прогресс-бара, но ошибки видны
curl -sSf https://api.example.com/health            # + ненулевой код выхода при 4xx/5xx
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com     # только код ответа
curl -sS -o /dev/null -D - https://example.com      # только заголовки ответа (обычный GET, а не HEAD)
curl -sSi https://example.com                       # заголовки + тело
```

* **`-s` без `-S`** скрывает и ошибки — скрипт молча получит пустой ответ.
* **Без `-f`** curl завершается с кодом `0` даже при `500 Internal Server Error`: для него «запрос выполнен». В скриптах и CI — почти всегда `-f`.
* `--fail-with-body` — как `-f`, но тело ответа с ошибкой всё равно выводится (видно, *что* сказал сервер).
* `-I` отправляет `HEAD`, а некоторые приложения отвечают на `HEAD` не так, как на `GET` (или вообще 405). Для «посмотреть заголовки» надёжнее `-sS -o /dev/null -D -`.

### -w: код ответа, тайминги, IP

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s %{remote_ip}\n' https://example.com
# 200 0.231544s 93.184.215.14
```

| Переменная | Что это |
|---|---|
| `%{http_code}` | код ответа |
| `%{remote_ip}`, `%{remote_port}` | куда реально подключились (полезно за балансировщиком/DNS) |
| `%{time_namelookup}` | DNS |
| `%{time_connect}` | + TCP-соединение |
| `%{time_appconnect}` | + TLS handshake |
| `%{time_starttransfer}` | + до первого байта ответа (**TTFB** — сколько думал сервер) |
| `%{time_total}` | всё время |
| `%{size_download}` | размер тела |
| `%{url_effective}` | итоговый URL после редиректов (`-L`) |
| `%{num_redirects}` | число редиректов |
| `%{ssl_verify_result}` | `0` — сертификат проверен успешно |
| `%{exitcode}`, `%{errormsg}` | код выхода и текст ошибки curl |
| `%header{name}` | значение заголовка ответа (curl 7.84+) |
| `%{json}` | **все переменные сразу в JSON** |

Разбивка времени запроса — классика диагностики «почему медленно»:

```bash
cat > curl-time.txt <<'EOF'
    dns:      %{time_namelookup}s
    connect:  %{time_connect}s
    tls:      %{time_appconnect}s
    ttfb:     %{time_starttransfer}s
    total:    %{time_total}s
    code:     %{http_code}  ip: %{remote_ip}
EOF
curl -sS -o /dev/null -w @curl-time.txt https://example.com
```

* большой `dns` — медленный резолвер;
* большая разница `connect` − `dns` — сеть/расстояние;
* большая разница `ttfb` − `tls` — **медленное приложение или база**;
* большая разница `total` − `ttfb` — большой ответ или медленный канал.

```bash
curl -sS -o /dev/null -w '%{json}' https://example.com | jq '{code: .http_code, total: .time_total, ip: .remote_ip}'
```

## Методы, заголовки, тело запроса

```bash
curl -X DELETE https://api.example.com/items/42
curl -H 'Authorization: Bearer '"$TOKEN" -H 'Accept: application/json' https://api.example.com/me
curl -A 'my-healthcheck/1.0' https://example.com      # User-Agent
curl -e 'https://referer.example' https://example.com # Referer
```

### JSON

```bash
# современный способ (curl 7.82+): тело + Content-Type + Accept одной опцией
curl -sS --json '{"name":"web","replicas":3}' https://api.example.com/apps

# классический — работает на любой версии
curl -sS -X POST https://api.example.com/apps \
  -H 'Content-Type: application/json' \
  -d '{"name":"web","replicas":3}'

# тело из файла (@) и из stdin (@-)
curl -sS --json @payload.json https://api.example.com/apps
jq -n --arg name "$APP" '{name: $name}' | curl -sS --json @- https://api.example.com/apps

# ответ сразу в jq
curl -sSf https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name'
```

> `-d` **сам** делает запрос POST и ставит `Content-Type: application/x-www-form-urlencoded`. Если отправляешь JSON через `-d` без `-H 'Content-Type: application/json'`, многие API ответят `400`/`415`.

### Варианты -d

| Флаг | Что делает |
|---|---|
| `-d 'a=1&b=2'` | тело как есть (удаляет переводы строк из `@file`) |
| `-d @file` | тело из файла |
| `--data-binary @file` | тело из файла **байт в байт** (для бинарных данных и многострочного текста) |
| `--data-raw '...'` | как `-d`, но `@` в начале не считается файлом |
| `--data-urlencode 'q=a b&c'` | закодировать значение для URL/формы |
| `-G` + `-d`/`--data-urlencode` | превратить данные в **query string** GET-запроса |

```bash
# GET с параметрами, корректно закодированными
curl -sS -G https://prometheus.example.com/api/v1/query --data-urlencode 'query=sum(rate(http_requests_total[5m]))'
```

### Формы и загрузка файлов

```bash
curl -F 'file=@backup.tar.gz' -F 'comment=nightly' https://upload.example.com/   # multipart/form-data
curl -T artifact.zip https://nexus.example.com/repository/raw/artifact.zip       # PUT файла
```

## Аутентификация и секреты

```bash
curl -u admin:secret https://jenkins.example.com/api/json           # Basic
curl -u admin https://jenkins.example.com/api/json                  # пароль спросит интерактивно
curl --oauth2-bearer "$TOKEN" https://api.example.com/              # = -H "Authorization: Bearer ..."
curl -b cookies.txt -c cookies.txt https://app.example.com/login    # читать/сохранять cookies
```

**Секреты в командной строке видны** в `ps aux` другим пользователям сервера и попадают в историю shell и логи CI. Безопаснее:

```bash
# заголовок из файла (curl 7.55+)
printf 'Authorization: Bearer %s\n' "$TOKEN" > /run/user/$(id -u)/auth.hdr
curl -H @/run/user/$(id -u)/auth.hdr https://api.example.com/

# логины в ~/.netrc (chmod 600)
#   machine api.example.com login deploy password s3cr3t
curl -n https://api.example.com/

# всё в конфиг-файл curl
curl -K secrets.curlrc https://api.example.com/
```

## Надёжность в скриптах: таймауты и повторы

```bash
# TCP не дольше 5 с, весь запрос не дольше 30 с, до 5 повторов с паузой 2 с,
# «Connection refused» тоже считать временной ошибкой
curl -sSf \
  --connect-timeout 5 \
  --max-time 30 \
  --retry 5 \
  --retry-delay 2 \
  --retry-connrefused \
  https://api.example.com/health
```

> После `\` в конце строки не должно быть ничего — даже комментария или пробела, иначе перенос не сработает.

| Флаг | Что делает |
|---|---|
| `--connect-timeout N` | таймаут установки соединения |
| `-m N`, `--max-time N` | таймаут всего запроса — **без него curl может висеть бесконечно** |
| `--retry N` | повторы при временных ошибках: таймаут, `408`, `429`, `5xx` (`500`, `502`, `503`, `504`) |
| `--retry-connrefused` | повторять и при `Connection refused` (сервис ещё стартует) |
| `--retry-all-errors` | повторять при **любой** ошибке (curl 7.71+) — осторожно с неидемпотентными POST |
| `--retry-max-time N` | общий лимит времени на все повторы |
| `-C -` | докачать файл с места обрыва |
| `--limit-rate 1M` | ограничить скорость |

### Дождаться, пока сервис поднимется

```bash
# в скрипте деплоя / CI
for i in $(seq 1 30); do
  curl -sSf --max-time 3 http://localhost:8000/readyz >/dev/null && { echo ready; break; }
  echo "ещё не готов ($i)"; sleep 2
done

# или одной командой
curl -sSf --retry 30 --retry-delay 2 --retry-connrefused --max-time 5 http://localhost:8000/readyz
```

```dockerfile
# Dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -fsS --max-time 2 http://localhost:8000/healthz || exit 1
```

> В Kubernetes для проб curl не нужен: `httpGet` в `livenessProbe`/`readinessProbe` делает то же самое силами kubelet, и в образе не нужен curl.

## Проверка без DNS: --resolve, Host, --connect-to

Новый сервер, балансировщик или Ingress, а DNS ещё смотрит на старый адрес. Проверить новый адрес **с правильным именем**:

```bash
# 1. --resolve — имя → IP только для этого запроса; правильно работает и с HTTPS (SNI, проверка сертификата)
curl -sS --resolve app.example.com:443:203.0.113.10 https://app.example.com/healthz

# 2. заголовок Host — только для HTTP: подставить домен, подключаясь по IP
curl -sS -H 'Host: app.example.com' http://203.0.113.10/healthz

# 3. --connect-to — «подключайся к другому host:port, но всё остальное как для исходного»
curl -sS --connect-to app.example.com:443:new-lb.example.net:443 https://app.example.com/
```

Типичный случай — проверить Ingress в kind или minikube:

```bash
curl -sS -H 'Host: app.localhost' http://127.0.0.1/                 # HTTP
curl -sS --resolve app.localhost:443:127.0.0.1 -k https://app.localhost/   # HTTPS с самоподписанным сертификатом
```

> Для HTTPS `-H 'Host: ...'` не поможет: TLS-handshake (SNI) идёт **до** HTTP-заголовков, сервер выдаст сертификат «по умолчанию», и проверка упадёт. Используй `--resolve` или `--connect-to`.

## TLS

```bash
curl -vI https://example.com 2>&1 | grep -E "subject:|issuer:|expire date:|SSL certificate verify"
curl --cacert /etc/ssl/company-ca.pem https://internal.example.com/       # свой корневой CA
curl --cert client.crt --key client.key https://mtls.example.com/         # mTLS: клиентский сертификат
curl --tlsv1.2 --tls-max 1.2 https://example.com                          # проверить, работает ли TLS 1.2
curl --http1.1 https://example.com                                        # принудительно HTTP/1.1
curl --http2 https://example.com                                          # HTTP/2
curl -sS -o /dev/null -w '%{ssl_verify_result}\n' https://example.com     # 0 — проверка прошла
```

**`-k` / `--insecure`** отключает проверку сертификата целиком: curl поверит любому серверу, в том числе атакующему посередине. Допустимо **только** для отладки на своём стенде. В скриптах и CI вместо `-k` — `--cacert` со своим CA или установка CA в систему (см. [Linux: каталоги](linux-filesystem.md), раздел про сертификаты).

Срок действия сертификата удобнее смотреть через `openssl` — см. [Типовые инциденты](incidents-practice.md), пункт про TLS.

## Скачивание

```bash
curl -fsSLO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
curl -fsSLOJ https://example.com/download?id=42      # -J: имя файла из заголовка Content-Disposition
curl -C - -O https://example.com/big.iso             # докачать
curl -# -O https://example.com/big.iso               # прогресс-бар полоской

# проверить контрольную сумму
curl -fsSLO https://example.com/tool.tar.gz
curl -fsSL https://example.com/tool.tar.gz.sha256 | sha256sum -c -
```

`-fsSL` — стандартная связка для скачивания: **f**ail на ошибке HTTP, **s**ilent, но **S**how errors, **L**ocation (редиректы). Без `-L` с GitHub Releases скачается HTML страницы редиректа, а без `-f` — HTML страницы 404 под видом бинарника.

### curl | sh

```bash
curl -fsSL https://get.docker.com | sh
```

Удобно, но выполняет **чужой код с твоими правами**, а при обрыве соединения может выполниться половина скрипта. Безопаснее:

```bash
curl -fsSL -o install.sh https://get.docker.com
less install.sh                     # прочитать
sh install.sh
```

## Прокси

```bash
curl -x http://proxy.corp:3128 https://example.com
curl -x socks5h://localhost:1080 https://internal.example.com     # через ssh -D (h — DNS тоже через прокси)
curl --noproxy '*' http://localhost:8080                          # мимо прокси

# переменные окружения (понимают curl, pip, apt, docker CLI…)
export https_proxy=http://proxy.corp:3128 http_proxy=http://proxy.corp:3128
export no_proxy=localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8
```

> В корпоративной сети частая причина «curl из пода не работает» — `https_proxy` задан, а `no_proxy` не включает внутренние адреса кластера.

## Docker, Kubernetes, облака

```bash
# Docker Engine API через сокет
curl -sS --unix-socket /var/run/docker.sock http://localhost/containers/json | jq '.[].Names'
curl -sS --unix-socket /var/run/docker.sock http://localhost/version | jq .ApiVersion

# Kubernetes API — проще всего через kubectl proxy (он сам добавит авторизацию)
kubectl proxy --port=8001 &
curl -sS http://127.0.0.1:8001/api/v1/namespaces/default/pods | jq -r '.items[].metadata.name'
curl -sS http://127.0.0.1:8001/healthz

# изнутри пода — с токеном сервис-аккаунта
SA=/var/run/secrets/kubernetes.io/serviceaccount
curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" \
  https://kubernetes.default.svc/api/v1/namespaces/$(cat $SA/namespace)/pods

# временный под с curl для проверки сервисов внутри кластера
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' http://app.app.svc.cluster.local/healthz

# Prometheus HTTP API
curl -sS -G http://localhost:9090/api/v1/query --data-urlencode 'query=up' | jq '.data.result[] | {job: .metric.job, up: .value[1]}'

# metadata service облака (AWS IMDSv2)
TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```

## Несколько запросов

```bash
curl -sS -o /dev/null -w '%{url_effective} %{http_code}\n' https://a.example.com https://b.example.com   # подряд
curl -Z -sS -o /dev/null -w '%{url_effective} %{http_code}\n' https://a.example.com https://b.example.com # параллельно (-Z)
curl -sS 'https://example.com/page/[1-5]' -o 'page_#1.html'             # диапазон в URL
curl -sS 'https://{api,www}.example.com/health'                          # перебор вариантов

# проверить список URL из файла
while read -r url; do
  printf '%s %s\n' "$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$url")" "$url"
done < urls.txt
```

> `[]` и `{}` curl понимает как шаблоны. Если они нужны буквально (например, в query `filter[name]=x`), отключи разбор: `-g` (`--globoff`).

## Конфиг ~/.curlrc

```
# ~/.curlrc — применяется ко всем запросам
connect-timeout = 5
show-error
silent
```

В скриптах, которые должны вести себя одинаково на любой машине, добавляй **`-q` первым аргументом** — curl проигнорирует `~/.curlrc`.

## Коды выхода

Код выхода curl (`echo $?`) — **не** HTTP-код. Он говорит, что случилось на уровне соединения:

| Код | Значит | Типичная причина |
|---|---|---|
| `0` | успех (**включая HTTP 4xx/5xx без `-f`**) | |
| `3` | неправильный URL | опечатка, не закодированы пробелы/спецсимволы |
| `6` | не удалось разрешить имя | DNS, опечатка в домене |
| `7` | не удалось подключиться | порт закрыт, сервис не запущен, `Connection refused` |
| `22` | HTTP-ошибка ≥ 400 (с `-f`) | 404, 500, 503 |
| `28` | таймаут | `--connect-timeout` / `--max-time`, firewall молча отбрасывает пакеты |
| `35` | ошибка TLS-handshake | несовместимые версии TLS / шифры |
| `47` | слишком много редиректов | петля редиректов (HTTP ↔ HTTPS) |
| `52` | пустой ответ от сервера | процесс упал на запросе, неправильный порт (HTTP на HTTPS-порт) |
| `56` | ошибка при получении данных | соединение оборвали (reset) |
| `60` | сертификат не прошёл проверку | самоподписанный, истёк, нет промежуточного, нет CA |

```bash
curl -sS -o /dev/null http://127.0.0.1:18099/; echo "exit=$?"
# curl: (7) Failed to connect to 127.0.0.1 port 18099 after 0 ms: Couldn't connect to server
# exit=7
```

```bash
# в скрипте: различать «сервис лежит» и «сервис отвечает ошибкой»
code=$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$URL"); rc=$?
if   [ $rc -ne 0 ];    then echo "нет соединения (curl exit $rc)"
elif [ "$code" -ge 500 ]; then echo "сервис отвечает $code"
else echo "ok $code"; fi
```

## Частые ошибки

| Ошибка | Что происходит | Как правильно |
|---|---|---|
| URL с `&` или `?` без кавычек | shell отправит процесс в фон по `&`, параметры потеряются | всегда `'https://...?a=1&b=2'` в кавычках |
| Нет `-f` в скрипте/CI | `500` считается успехом, пайплайн «зелёный» | `-fsS` |
| `-s` без `-S` | ошибка не видна, в логе пусто | `-sS` |
| Нет `--max-time` | скрипт висит бесконечно на «мёртвом» хосте | `--connect-timeout` + `--max-time` |
| JSON через `-d` без заголовка | сервер получает form-urlencoded → `400`/`415` | `--json` или `-H 'Content-Type: application/json'` |
| `-X GET -d ...` | тело в GET-запросе — многие серверы его игнорируют | `-G --data-urlencode` |
| `-X POST` + `-L` | после редиректа curl продолжает слать POST туда, куда браузер послал бы GET | не задавать `-X` без нужды: `-d` сам делает POST |
| `-k` в скриптах | MITM-атака пройдёт незаметно | `--cacert` / CA в системе |
| Токен в командной строке | виден в `ps`, истории, логах CI | `-H @file`, `~/.netrc`, `-K config` |
| `-H 'Host: ...'` для HTTPS | сертификат не того домена, ошибка 60 | `--resolve` / `--connect-to` |
| Скачивание без `-L` и `-f` | вместо бинарника сохраняется HTML редиректа или 404 | `-fsSL` |

## Best Practices

* **В скриптах всегда `-fsS` + `--connect-timeout` + `--max-time`**, при необходимости `--retry`.
* **URL — в одинарных кавычках.**
* **`-v` — первый шаг диагностики**, `-w` с таймингами — когда «медленно».
* **`--resolve` для проверки нового сервера/балансировщика** до переключения DNS.
* **Никогда `-k` вне отладки**, секреты — не в аргументах командной строки.
* **Скачанное проверяй** (`sha256sum -c`), чужие скрипты — сначала прочитай.
* **Ответы API — в `jq`**, а не грепом по JSON.
