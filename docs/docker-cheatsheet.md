# Docker: шпаргалка топ-20 команд

Самое частое в работе с Docker. Быстрые команды для образов, контейнеров, сети и томов.

> Подробно по каждой команде: [Docker: команды с подробным описанием](docker-commands.md). Теория — [Docker (теория)](docker.md).

## Топ-20 команд

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | образы | `docker build -t <name> .` | собрать образ из Dockerfile |
| 2 | образы | `docker images` | список локальных образов |
| 3 | образы | `docker rmi <img>` | удалить образ |
| 4 | запуск | `docker run -d --name app -p 8080:80 <img>` | запустить контейнер в фоне с пробросом порта |
| 5 | запуск | `docker run -it <img> sh` | запустить интерактивно с шеллом |
| 6 | запуск | `docker run --rm <img>` | запустить и удалить после остановки |
| 7 | запуск | `docker run -v $(pwd):/data <img>` | смонтировать том |
| 8 | просмотр | `docker ps` | работающие контейнеры |
| 9 | просмотр | `docker ps -a` | все контейнеры (включая остановленные) |
| 10 | исполнение | `docker exec -it <id> sh` | зайти внутрь работающего контейнера |
| 11 | исполнение | `docker exec <id> ls /app` | выполнить команду внутри контейнера |
| 12 | логи | `docker logs <id>` | логи контейнера |
| 13 | логи | `docker logs -f <id>` | следить за логами в реальном времени |
| 14 | остановка | `docker stop <id>` | остановить контейнер |
| 15 | удаление | `docker rm <id>` | удалить контейнер |
| 16 | инспекция | `docker inspect <id>` | детальная информация о контейнере |
| 17 | порты | `docker port <id>` | какие порты проброшены |
| 18 | ресурсы | `docker stats` | живой монитор CPU/памяти контейнеров |
| 19 | сеть | `docker network ls` | список сетей |
| 20 | тома | `docker volume ls / inspect` | список/детали томов |

## Компактные everyday-сценарии

```bash
# Собрать и запустить
docker build -t my-app .
docker run -d --name app -p 8080:80 my-app
docker ps

# Зайти внутрь и посмотреть логи
docker exec -it app sh
docker logs -f app

# Остановить и почистить
docker stop app && docker rm app
docker rmi my-app
```

## Работа с сетью и томами

```bash
docker network create my-net        # создать сеть
docker run --network my-net --name app -d nginx
docker volume create data-vol       # создать том
docker run -v data-vol:/data -d redis
```

## Быстрая навигация

- **Контейнеры**: `docker ps`, `docker stop`, `docker rm`, `docker exec`, `docker logs`
- **Образы**: `docker build`, `docker images`, `docker rmi`
- **Сеть**: `docker network ls/create/inspect`
- **Тома**: `docker volume ls/create/inspect`
- **Диагностика**: `docker inspect`, `docker stats`, `docker port`

> Все команды с флагами и деталями — на странице [Docker: команды с подробным описанием](docker-commands.md).
