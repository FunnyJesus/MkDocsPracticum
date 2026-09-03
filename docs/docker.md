# Docker

Docker — платформа для контейнеризации приложений. Позволяет упаковать приложение со всеми его зависимостями в изолированный контейнер, который одинаково работает на любой системе.

`контейнер` - изолированный процесс с собственным пространством имён (сеть, файловая система, процессы).

`образ (image)` - неизменяемый шаблон, из которого создаются контейнеры. Состоит из слоёв.

`Dockerfile` - файл с инструкциями для сборки образа.

`volume` - постоянный том, позволяющий хранить данные между пересозданиями контейнеров.

> Практический пример: система «DocFlow» состоит из двух сервисов — image-compress (Python) и image-serve (Go), которые используют общий том для хранения сжатых изображений, а запросы к ним проходят через прокси nginx.

## Инструкции Dockerfile

Dockerfile — текстовый файл с пошаговыми инструкциями, по которым Docker собирает образ. Каждая инструкция создаёт новый слой образа. Разберём все основные директивы на примере простого приложения Python.

### Простейший Dockerfile

```dockerfile
# Базовый образ (обязательный!). Пиннутая версия для воспроизводимости.
FROM python:3.12-slim

# Параметр сборки, который можно переопределить на этапе build.
ARG APP_VERSION=latest

# Переменная окружения — будет доступна в контейнере при запуске.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Рабочий каталог: все последующие RUN/COPY/CMD выполняются отсюда.
WORKDIR /app

# Копирование файла внутрь образа.
COPY requirements.txt .

# Установка зависимостей в слой RUN.
RUN pip install --no-cache-dir -r requirements.txt

# Копирование исходного кода (после зависимостей — для кэширования).
COPY app.py .

# Создание непривилегированного пользователя и каталога данных.
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /data \
    && chown appuser:appuser /data

# Переключение на непривилегированного пользователя (безопасность).
USER appuser

# Объявление порта, который слушает приложение (информационное).
EXPOSE 8000

# Команда по умолчанию при запуске контейнера (exec-форма).
CMD ["python", "app.py"]
```

### Разбор каждой инструкции

### FROM
* `FROM <образ>:<тег>` - задаёт **базовый образ**. Обязательная первая инструкция (кроме случая с `ARG` перед ней).
* `FROM <образ> AS <имя>` - даёт стадии имя (используется в multi-stage сборке).

```dockerfile
FROM python:3.12-slim
FROM golang:1.21-alpine AS builder
```
> Пинни тег версии! `FROM python` без тега тянет `latest` и делает сборку невоспроизводимой.

### ARG
* `ARG <ИМЯ>[=<значение>]` - объявляет **параметр сборки** (сборщика, не рантайма). Доступен только внутри Dockerfile на этапе build, в контейнер не попадает.

```dockerfile
ARG APP_VERSION=latest
RUN echo "VERSION=$APP_VERSION"
```
Передать при сборке: `docker build --build-arg APP_VERSION=1.2 .`
> В отличие от `ENV`, значение `ARG` не сохраняется в запущенном контейнере.

### ENV
* `ENV <ИМЯ>=<значение>` - задаёт **переменную окружения**, которая попадёт в запущенный контейнер (и доступна в RUN на этапе сборки).

```dockerfile
ENV COMPRESS_RATIO=10
ENV IMAGE_PATH=/data/images
```
> Значение `ENV` видит и сборка, и сам контейнер. `ARG` доступен только при сборке.

### WORKDIR
* `WORKDIR <путь>` - устанавливает **рабочий каталог** для последующих RUN/CMD/COPY/ENTRYPOINT. Если каталога нет — создаётся автоматически.

```dockerfile
WORKDIR /app
RUN python --version    # выполнится в /app
```
> Лучше `WORKDIR`, чем `RUN cd /app && ...` — читается яснее и применяется ко всем инструкциям разом.

### COPY
* `COPY <src> <dest>` - копирует **файлы/каталоги** из контекста сборки в образ.
* `COPY --from=<стадия>` - копирует из другой стадии multi-stage сборки.

```dockerfile
COPY requirements.txt .        # файл в контексте -> текущий WORKDIR
COPY server.py /app/server.py  # с явным путём назначения
COPY --from=builder /build/server /server
```
> Копируй зависимости ДО кода, чтобы изменение кода не переустанавливало пакеты.

### ADD
* `ADD <src> <dest>` - как `COPY`, но дополнительно умеет распаковывать архивы и скачивать по URL.

```dockerfile
ADD app.tar.gz /app/   # распакует архив
```
> При прочих равных предпочитают `COPY` — поведение ADD с распаковкой бывает неожиданным.

### RUN
* `RUN <команда>` - выполняет команду **на этапе сборки** и фиксирует результат как слой образа.

```dockerfile
RUN pip install --no-cache-dir -r requirements.txt
RUN useradd --create-home --uid 10001 appuser && mkdir -p /data
```
> Блокируется, если нет кэша слоя. Часто комбинируют в одну RUN, чтобы меньше слоёв: `RUN apt-get update && apt-get install -y pkg`.

### USER
* `USER <имя>|<uid>` - переключает пользователя для последующих инструкций и запуска контейнера (безопасность).

```dockerfile
USER appuser
USER 10001:10001
```
> Запуск от root — плохая практика. Создай пользователя через `RUN useradd ...`, затем `USER`.

### EXPOSE
* `EXPOSE <порт>` - **информативно** объявляет, какой порт слушает приложение. Само по себе не публикует порт наружу (нужен `-p` при `docker run`).

```dockerfile
EXPOSE 18080
```
> Это метаданные для читателя образа и для `-P` (автопубликация всех EXPOSE).

### CMD
* `CMD` - задаёт **команду по умолчанию** при запуске контейнера. Переопределяется аргументом `docker run`.
* `CMD ["cmd", "arg"]` - **exec-форма** (рекомендуемая): процесс запускается напрямую как PID 1, корректно получает Ctrl+C/SIGINT.
* `CMD command arg` - shell-форма (через `sh -c`), сигналы обрабатываются хуже.

```dockerfile
CMD ["python", "server.py"]        # exec-форма — правильно!
CMD python server.py                 # shell-форма — лучше избегать
```
> Exec-форма обязательна для корректной остановки контейнера через Ctrl+C.

### ENTRYPOINT
* `ENTRYPOINT` - задаёт команду, которая **не переопределяется** аргументами `docker run` (в отличие от CMD). Часто используют вместе с CMD: ENTRYPOINT задаёт исполняемый файл, CMD — его аргументы по умолчанию.

```dockerfile
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
```
```dockerfile
ENTRYPOINT ["python", "app.py"]   # CMD послужит аргументами
CMD ["--port", "8000"]
```
> Разница: `docker run image --help` — при ENTRYPOINT это `python app.py --help`, при CMD это перезапишет CMD.

### VOLUME
* `VOLUME ["/path"]` - объявляет точку монтирования как **анонимный том** при запуске контейнера.

```dockerfile
VOLUME ["/data"]
```
> Анонимный том исчезает при удалении контейнера. Для общего хранения между несколькими контейнерами используют именованный том через `-v` при `docker run`.

### LABEL
* `LABEL <ключ>=<значение>` - добавляет метаданные к образу (версия, автор, описание).

```dockerfile
LABEL version="1.0"
LABEL description="Сервис сжатия изображений"
```

### HEALTHCHECK
* `HEALTHCHECK` - задаёт команду, проверяющую «живость» контейнера (для оркестрации и статуса healthy).

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:18080/ || exit 1
```

### .dockerignore
* `.dockerignore` - файл со списком путей, исключаемых из контекста сборки (аналог `.gitignore`).

```
__pycache__/
*.pyc
.git
venv/
```

## Сравнение: CMD vs ENTRYPOINT vs RUN

| Инструкция | Когда выполняется | Можно переопределить? |
|------------|-------------------|------------------------|
| `RUN` | при сборке образа | — |
| `CMD` | при запуске контейнера | да (`docker run image <cmd>`) |
| `ENTRYPOINT` | при запуске контейнера | частично (только через `--entrypoint`) |
| `ENV` | окружение в контейнере | да (через `-e`) |
| `ARG` | только на этапе сборки | да (через `--build-arg`) |


### image-compress (Python) — воспроизводимость, кэш, непривилегированный юзер

```dockerfile
FROM python:3.12-slim

WORKDIR /app

# зависимости копируются ДО кода — изменение server.py не переустанавливает пакеты
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# создаём пользователя и каталог, даём права на запись в общий том
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /data/images \
    && chown appuser:appuser /data/images

USER appuser

ENV IMAGE_PATH=/data/images
EXPOSE 18080

# exec-форма -> python как PID 1, корректный Ctrl+C
CMD ["python", "server.py"]
```

### image-serve (Go) — multi-stage сборка, маленький образ

```dockerfile
# стадия сборки
FROM golang:1.21-alpine AS builder
WORKDIR /build
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server .

# финальная стадия — только бинарник
FROM scratch
USER 10001:10001
WORKDIR /data/images
COPY --from=builder /build/server /server
CMD ["/server", "--image_path=/data/images/"]
```

## Ключевые понятия и правила

### Пиннинг версии базового образа (воспроизводимость)
`FROM python` без тега тянет `latest` — сборка невоспроизводима. Всегда указывай версию: `FROM python:3.12-slim`, `FROM golang:1.21-alpine`.

### Порядок копирования (кэширование слоёв)
Каждый `COPY`/`RUN` — отдельный кэшируемый слой. Сначала копируй зависимости (`requirements.txt`), потом код. Тогда изменение кода не переустанавливает пакеты.

### Exec-форма CMD (Ctrl+C)
`CMD ["python", "server.py"]` — exec-форма: процесс становится PID 1 и корректно получает сигналы. Shell-форма `CMD python server.py` не всегда пересылает Ctrl+C.

### Непривилегированный пользователь (безопасность)
Запуск от root — небезопасно. Используй `USER`:
- в Python-образе: `useradd --create-home --uid 10001 appuser` + `USER appuser`
- в scratch: `USER 10001:10001` (нет useradd)

> Важно: uid контейнеров должны совпадать (например 10001), иначе один не сможет писать в общий том, принадлежащий другому.

### Multi-stage сборка (размер образа)
`FROM golang AS builder` ... `FROM scratch` — в финальный образ попадает только бинарник. Плюс `CGO_ENABLED=0` для статической сборки и `-ldflags="-s -w"` для убирания отладочной информации. Итог ~10 МБ.

### Общий том между контейнерами
Один volume монтируется в оба контейнера на один путь:
```
image-compress: IMAGE_PATH=/data/images  --> volume "images"
image-serve:    image_path=/data/images/  --> volume "images"
```

## Полный пример запуска системы DocFlow

```bash
# 1. Сборка образов
docker build -t image-compress ./image-compress
docker build -t image-serve ./image-serve

# 2. Сеть и том
docker network create images
docker volume create images
docker run --rm -v images:/data/images busybox chown -R 10001:10001 /data/images

# 3. image-compress (пишет в общий том)
docker run -d --name image-compress \
  --network images \
  -e COMPRESS_RATIO=10 \
  -e IMAGE_PATH=/data/images \
  -v images:/data/images \
  image-compress

# 4. image-serve (читает из общего тома)
docker run -d --name image-serve \
  --network images \
  -v images:/data/images \
  image-serve

# 5. nginx-прокси (единственная публикация порта 18080)
docker run -d --name image-proxy \
  --network images \
  -p 18080:18080 \
  -v "$(pwd)/proxy/conf.d:/etc/nginx/conf.d:ro" \
  nginx:1.27-alpine

# 6. Проверка
bash test.sh   # -> "test OK!"
```

## Пространства имён (nsenter)

Контейнер изолирован через пространства имён (network, pid, mount и др.). На Linux-хосте можно «войти» в сетевое пространство имён контейнера:

```bash
# PID контейнера
SERVE_PID=$(docker inspect -f '{{.State.Pid}}' image-serve)

# сетевые интерфейсы
nsenter -t $SERVE_PID -n ip addr

# таблица маршрутизации
nsenter -t $SERVE_PID -n ip route

# открытые TCP-порты
nsenter -t $SERVE_PID -n ss -lnt
```

> На macOS (Docker Desktop) `nsenter` недоступен. Обходной путь — контейнер в том же network namespace:
> ```
> docker run --rm --network container:image-serve alpine sh -c 'ip addr; ip route; netstat -lnt'
> ```

## iptables: таблица nat

Публикация порта реализуется через DNAT-правило в цепочке `DOCKER` таблицы `nat`:

```bash
# на Linux-хосте
iptables -t nat -L DOCKER -n -v
iptables -t nat -S DOCKER
```

Ожидаемый вывод (порт 18080 → контейнер proxy):
```
Chain DOCKER (2 references)
target  prot opt source          destination
DNAT    tcp   0.0.0.0/0         0.0.0.0/0     tcp dpt:18080 to:172.20.0.2:18080
```

> На macOS (Docker Desktop) правила nat хост-VM работают через nftables и из контейнера не видны. Косвенное доказательство — `docker port image-proxy` или `curl localhost:18080`.

> Команды `docker` — на странице [Docker: команды с подробным описанием](docker-commands.md).
> Мини-шпаргалка: [Docker: шпаргалка топ-20 команд](docker-cheatsheet.md).
