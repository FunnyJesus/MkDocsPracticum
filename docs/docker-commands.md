# Docker: команды с подробным описанием

Основные команды `docker`. Теория (Dockerfile, понятия, best practices) — на странице [Docker (теория)](docker.md).

> Мини-шпаргалка «топ-20»: [Docker: шпаргалка топ-20 команд](docker-cheatsheet.md).

Вступление про контейнеры, образы и терминологию — в [Docker (теория)](docker.md).

---
## Работа с образами

### docker build
* `docker build <context>` - собирает образ из Dockerfile, используя указанный контекст сборки
* `docker build -t <имя>:<тег> .` - собрать и присвоить имя/тег образу (точка = текущий каталог как контекст)
* `--no-cache` - пересборка без использования кэша слоёв (нужно, если менялся uid/пользователь в RUN)
* `--build-arg <VAR>=<value>` - передать значение ARG-переменной в Dockerfile при сборке
* `-f <путь>` - указать другой файл Dockerfile (по умолчанию ./Dockerfile)

```
$ docker build -t image-compress ./image-compress
$ docker build -t image-serve --no-cache .
$ docker build --build-arg VERSION=1.2 -t app:v1.2 .
```

> `./image-compress` — это «контекст сборки»: каталог, файлы которого Docker отправляет в демон для сборки. Нельзя ссылаться (COPY) на файлы вне контекста.

### docker images
* `docker images` - список локальных образов (репозиторий, тег, размер)
* `docker image rm <name>` - удаление образа

```
$ docker images
REPOSITORY      TAG       IMAGE ID       CREATED       SIZE
image-compress  latest    07bc69b4e146   2 hours ago   152MB
image-serve     latest    ec1d1bc96d9a   2 hours ago   10.1MB
```

> image-serve собран в scratch и весит ~10 МБ, image-compress с Python+Pillow тяжелее.
## Работа с контейнерами

### docker run
* `docker run <image>` - создать и запустить контейнер из образа (создаёт новый контейнер поверх образа)

**Основные флаги:**
* `-d` - запуск в фоне (detached), не блокирует терминал
* `--name <name>` - задать имя контейнера (важно: это имя используется для DNS-резолвинга между контейнерами)
* `-p <host>:<container>` - публикация порта: проброс порта хоста на порт контейнера
* `-P` - автоматически опубликовать все порты, объявленные через EXPOSE
* `-e <VAR>=<value>` - передать переменную окружения в контейнер
* `-v <volume>:/path` - смонтировать том (volume) в каталог контейнера
* `--network <net>` - подключить контейнер к указанной сети
* `-it` - интерактивный режим + псевдо-терминал (для отладки / команды с вводом)
* `--rm` - автоматически удалить контейнер после остановки (удобно для одноразовых задач)
* `--restart <policy>` - политика перезапуска: no, on-failure, always, unless-stopped
* `--env-file <file>` - загрузить переменные окружения из файла

**Порядок: `docker run [флаги] <образ> [команда]`** — если передана команда, она выполнится вместо CMD из образа.

```
$ docker run -d --name image-compress \
    --network images \
    -e COMPRESS_RATIO=10 \
    -e IMAGE_PATH=/data/images \
    -v images:/data/images \
    image-compress
```

```
$ docker run -it --rm alpine sh          # временный контейнер для отладки
$ docker run -p 18080:18080 nginx         # проброс порта
$ docker run --env-file .env app          # окружение из файла
```

> `-p 18080:18080` — публикует порт 18080 хоста на порт 18080 контейнера. Два контейнера не могут одновременно занять один хост-порт, поэтому наружу порт публикует только nginx, а он внутри сети распределяет запросы.

### docker ps
* `docker ps` - список запущенных контейнеров
* `-a` - показать также остановленные контейнеры
* `--format "table ..."` - кастомный формат вывода

```
$ docker ps
NAMES          IMAGE           STATUS          PORTS
image-proxy    nginx:1.27-alpine  Up 3 minutes  0.0.0.0:18080->18080/tcp
image-serve    image-serve     Up 3 minutes
image-compress image-compress  Up 3 minutes
```
### docker exec
* `docker exec <name> <cmd>` - выполнить команду внутри работающего контейнера
* `-it` - интерактивный режим

```
$ docker exec image-proxy sh -c 'getent hosts image-serve'
172.20.0.3  image-serve
```

### docker logs
* `docker logs <name>` - показать логи контейнера

```
$ docker logs image-proxy
/docker-entrypoint.sh: Configuration complete; ready for start up
```

### docker stop / docker rm
* `docker stop <name>` - остановить контейнер (отправляет SIGTERM, затем SIGKILL)
* `docker rm <name>` - удалить остановленный контейнер
* `docker rm -f <name>` - принудительно остановить и удалить работающий контейнер
* `docker ps -a` - для просмотра остановленных контейнеров перед удалением

```
$ docker rm -f image-compress image-serve image-proxy
```

### docker inspect
* `docker inspect <name>` - подробная информация о контейнере (формат: `--format`)

```
$ docker inspect image-serve --format '{{.State.Pid}}'
82897
```

### docker port
* `docker port <name>` - показать публикацию портов контейнера

```
$ docker port image-proxy
18080/tcp -> 0.0.0.0:18080
```

### docker stats
* `docker stats` - мониторинг ресурсов контейнеров в реальном времени
* `--no-stream` - один снимок вместо непрерывного потока
* `--format "table ..."` - кастомный формат

```
$ docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
NAME             CPU %     MEM USAGE / LIMIT   MEM %     NET I/O          BLOCK I/O
image-proxy      2.65%     9.078MiB / 7.653GiB 0.12%     3.83MB / 3.81MB  0B / 4.1kB
image-serve      1.14%     3.547MiB / 7.653GiB 0.05%     147kB / 581kB    0B / 0B
image-compress   10.42%    26.99MiB / 7.653GiB 0.34%     2.97MB / 166kB   0B / 1.11MB
```

> image-compress ест больше CPU (10%) — сжатие изображений ресурсоёмко. image-serve на Go — всего 3.5 MiB памяти, что соответствует философии «простой и быстрый».

## Работа с сетью и томами

### docker network
* `docker network create <name>` - создать сеть
* `docker network inspect <name>` - показать информацию о сети (контейнеры, IP)
* `docker network ls` - список сетей

```
$ docker network inspect images
```

> Все контейнеры в одной user-defined bridge-сети видят друг друга по именам через встроенный DNS Docker (адрес 127.0.0.11). Именно поэтому nginx пишет `proxy_pass http://image-compress:18080`.

### docker volume
* `docker volume create <name>` - создать том
* `docker volume ls` - список томов
* `docker volume rm <name>` - удалить том
* `docker volume inspect <name>` - информация о томе

```
$ docker volume ls
DRIVER    VOLUME NAME
local     images
```

> Один и тот же volume `images` монтируется в image-compress и image-serve на путь `/data/images` — так они разделяют сжатые файлы: compress пишет, serve отдаёт.

### Встроенный DNS
* `docker exec <container> <getent hosts <name>>` - проверить резолвинг имени контейнера

```
$ docker exec image-proxy sh -c 'getent hosts image-compress; getent hosts image-serve'
172.20.0.2  image-compress
172.20.0.3  image-serve

$ docker exec image-compress cat /etc/resolv.conf
nameserver 127.0.0.11
```

> `127.0.0.11` — встроенный DNS-резолвер Docker. Он магически резолвит имена контейнеров в их IP.

