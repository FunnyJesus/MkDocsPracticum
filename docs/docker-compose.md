# Docker Compose

Docker Compose — инструмент для **определения и запуска многоконтейнерных приложений** одной командой. Вместо десятков `docker run` пишем один файл `compose.yaml`, в котором описываем сервисы, сети, тома и секреты.

> Практический пример (весь конспект построен вокруг него): система «Galactic Pizza» — межгалактическая пиццерия из микросервисов: `frontend` (React), `menu-service` (Node.js), `order-service` (Spring Boot), `redis` (кэш) и `nginx` (балансировщик). Разворачивается целиком одной командой `docker compose up`.

## Зачем нужен Compose

* **Один файл — вся архитектура.** Все сервисы, их зависимости и конфигурация описаны декларативно в `compose.yaml`.
* **Одна команда запуска.** `docker compose up` создаёт все контейнеры, сети, тома и секреты.
* **Воспроизводимость.** Окружение одинаково поднимается у любого, у кого есть `compose.yaml`.
* **Ordering-контроль.** Секция `depends_on` позволяет управлять порядком запуска.
* **Изоляция и масштабирование.** Сети и `deploy.replicas` из коробки.

## Базовые команды

| Команда | Действие |
|---|---|
| `docker compose up` | Создать и запустить сервисы (в фоне с `-d`) |
| `docker compose up -d` | Запуск в фоне (detached) |
| `docker compose up --build` | Пересобрать образы перед запуском |
| `docker compose down` | Остановить и удалить контейнеры + сети |
| `docker compose down -v` | Дополнительно удалить **тома** (осторожно: данные!) |
| `docker compose ps -a` | Список контейнеров с их статусом (UP / healthy / unhealthy) |
| `docker compose logs <svc>` | Логи конкретного сервиса |
| `docker compose logs -f <svc>` | Логи в режиме реального времени |
| `docker compose config` | Показать финальный конфиг (после подстановки переменных) + валидация |
| `docker compose restart <svc>` | Перезапустить сервис (например, чтобы nginx перечитал конфиг) |
| `docker compose scale <svc>=N` | Изменить число реплик на лету |

```
$ docker compose up --build -d
$ docker compose ps -a
$ docker compose logs -f nginx
```

## Структура compose.yaml

Верхнеуровневые ключи: `name`, `services`, `networks`, `volumes`, `secrets`.

```yaml
name: "balancer-pizza"          # имя проекта (префикс контейнеров/сетей)

services:                       # сервисы (контейнеры)
  redis: ...
  menu-service: ...
  order-service: ...
  frontend: ...
  nginx: ...

networks:                       # объявленные сети
  backend-net: {}
  frontend-net: {}

volumes:                        # объявленные именованные тома
  redis_data:

secrets:                        # секреты (файлы с паролями и т.п.)
  redis_password:
    file: ./secrets/redis_password.txt
```

> `name:` задаёт префикс, который ставится перед контейнерами, сетями и томами проекта (в примере — `balancer-pizza-redis-1`, `balancer-pizza-backend-net` и т.д.).

## Основные ключи сервиса

### image и build

Образ берём из реестра (`image`) **или** собираем из Dockerfile (`build`).

```yaml
redis:
  image: redis:7-alpine        # готовый образ из Docker Hub

menu-service:
  build:
    context: ./menu-service    # каталог с исходниками → образ собирается сам
```

> Совмещать `image` и `build` можно: тогда Compose соберёт образ из `context` и пометит его именем из `image`. Удобно для публикации.

### command

Команда, которая выполнится **внутри контейнера** вместо CMD из образа.

```yaml
redis:
  image: redis:7-alpine
  command: redis-server /usr/local/etc/redis/redis.conf --requirepass $$(cat /run/secrets/redis_password)
```

> `$$` — экранирование: Compose не подставляет переменную, а отдаёт `$` как есть в shell контейнера. То есть в контейнере выполнится `$(cat /run/secrets/redis_password)`, который прочитает пароль из файла секрета.
> Пути в `command` — это пути **внутри контейнера**, а не на хосте.

### environment

Переменные окружения. Список `- KEY=value` или словарь `KEY: value`.

```yaml
menu-service:
  environment:
    - REDIS_HOST=${REDIS_HOST}        # подстановка из .env
    - REDIS_PORT=${REDIS_PORT}
    - PORT=8000                       # жёсткое значение
    - ORDER_SERVICE_URL=${ORDER_SERVICE_URL}
```

> `${VAR}` подставляются Compose из файла `.env` в корне проекта или из окружения shell. Если переменной нет — подставится пустая строка и появится `WARN` в `docker compose config`.

> ⚠️ **Секреты (пароли) НЕ передают через environment.** Для этого есть отдельный механизм `secrets` — см. ниже.

### secrets

Монтирует секрет как файл в контейнер (по умолчанию в `/run/secrets/<имя>`).

```yaml
menu-service:
  secrets:
    - redis_password

# сам файл-источник объявляется на верхнем уровне:
secrets:
  redis_password:
    file: ./secrets/redis_password.txt
```

> Приложение читает пароль из файла `/run/secrets/redis_password`, а не получает его через env. Так пароль не «светится» в `docker inspect` и не попадает в историю контейнера.
> В контейнер `redis` секрет тоже нужно подключить (иначе `/run/secrets/...` там не существует).

### ports vs expose

* `ports: - "80:80"` — публикация порта **наружу** (на хост). Пользователь обращается к приложению через этот порт.
* `expose:` — только «декларация» порта внутри сети, наружу не публикуется.

```yaml
nginx:
  ports:
    - "80:80"          # наружу доступен порт 80
```

### volumes (сервис)

Монтирование томов **в конкретном сервисе**. Бывают двух типов:

* **Именованный том** — `имя:/путь`, данные переживают пересоздание контейнера.
* **Bind mount** — `./путь/на/хосте:/путь/в/контейнере`, привязка к файлу/каталогу хоста.

```yaml
redis:
  volumes:
    - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro   # bind mount (конфиг, read-only)
    - redis_data:/data                                          # именованный том (данные на диск)
```

> Redis пишет данные на диск в `/data`. Именно **именованный том** `redis_data` гарантирует, что история заказов переживёт рестарт/пересоздание контейнера — данные не удаляются.

### networks (сервис)

К каким сетям подключён сервис. Имя — **множественное число** `networks` (не `network`!).

```yaml
frontend:
  networks:
    - frontend-net

nginx:
  networks:
    - backend-net
    - frontend-net
```

### deploy.replicas

Число реплик (экземпляров) сервиса. Именно так масштабируются `menu-service` и `order-service` в 2 экземпляра.

```yaml
menu-service:
  deploy:
    replicas: 2
```

> Команда `docker compose up` учитывает `deploy.replicas` (Compose v2). Изменить число реплик на лету: `docker compose up -d --scale menu-service=3` или `docker compose scale menu-service=3`.

### depends_on

Порядок запуска относительно других сервисов. Простая форма — просто список имён. Расширенная — с **условием готовности** `condition`.

```yaml
nginx:
  depends_on:
    frontend:
      condition: service_healthy
    menu-service:
      condition: service_healthy
    order-service:
      condition: service_healthy
```

> `service_healthy` означает: «дождись, пока зависимый сервис пройдёт свой **healthcheck** и станет `healthy`». Без condition Compose ждёт только **запуска** контейнера, но не его готовности — фронтенд может ещё не отвечать, а мы уже шлём на него трафик.

### healthcheck

Проверка работоспособности контейнера. Если проверка проваливается `retries` раз подряд — статус `unhealthy`. Именно на него опирается `depends_on ... condition: service_healthy`.

```yaml
order-service:
  healthcheck:
    test: curl -f http://localhost:8001/actuator/health
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 30s   # не считать провалы во время долгого старта (Java/Spring)
```

> `start_period` важен для приложений, которые долго стартуют (например, Spring Boot). В течение этого окна healthcheck «не штрафуется» за неудачные попытки.

> ⚠️ Частая ошибка: `test: curl -f http://localhost:${PORT}/health`. Здесь `${PORT}` интерполируется **Compose** ещё до запуска, а не внутри контейнера. Лучше захардкодить порт: `curl -f http://localhost:8000/health`, иначе получишь битый URL вроде `localhost:/health`.

## Полный пример: compose.yaml для Galactic Pizza

```yaml
name: "balancer-pizza"

services:
  redis:
    image: redis:7-alpine
    networks:
      - backend-net
    command: redis-server /usr/local/etc/redis/redis.conf --requirepass $$(cat /run/secrets/redis_password)
    volumes:
      - ./redis/redis.conf:/usr/local/etc/redis/redis.conf:ro
      - redis_data:/data
    secrets:
      - redis_password
    healthcheck:
      test: redis-cli -a $$(cat /run/secrets/redis_password) ping
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s

  menu-service:
    build:
      context: ./menu-service
    networks:
      - backend-net
    deploy:
      replicas: 2
    environment:
      - REDIS_HOST=${REDIS_HOST}
      - REDIS_PORT=${REDIS_PORT}
      - PORT=8000
      - ORDER_SERVICE_URL=${ORDER_SERVICE_URL}
    secrets:
      - redis_password
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: curl -f http://localhost:8000/health
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

  order-service:
    build:
      context: ./order-service
    networks:
      - backend-net
    deploy:
      replicas: 2
    environment:
      - REDIS_HOST=${REDIS_HOST}
      - REDIS_PORT=${REDIS_PORT}
      - SERVER_PORT=8001
      - MENU_SERVICE_URL=${MENU_SERVICE_URL}
    secrets:
      - redis_password
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: curl -f http://localhost:8001/actuator/health
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s

  frontend:
    build:
      context: ./frontend
    networks:
      - frontend-net
    healthcheck:
      test: curl -f http://localhost/health
      interval: 10s
      timeout: 5s
      retries: 3

  nginx:
    build:
      context: ./nginx
    ports:
      - "80:80"
    networks:
      - backend-net
      - frontend-net
    depends_on:
      frontend:
        condition: service_healthy
      menu-service:
        condition: service_healthy
      order-service:
        condition: service_healthy
    healthcheck:
      test: curl -f http://localhost/
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  redis_data:

networks:
  backend-net: {}
  frontend-net: {}

secrets:
  redis_password:
    file: ./secrets/redis_password.txt
```

## Файл .env

`.env` в корне проекта хранит переменные для подстановки `${VAR}` в `compose.yaml`. Compose подхватывает его автоматически.

```
# .env
REDIS_HOST=redis
REDIS_PORT=6379
MENU_SERVICE_URL=http://menu-service:8000
ORDER_SERVICE_URL=http://order-service:8001
```

> ⚠️ `.env` не должен попадать в git (добавь его в `.gitignore`), особенно если там есть секреты. Для паролей лучше `secrets` + файл в каталоге, игнорируемом git.

## Типичные ошибки и их решение

| Симптом | Причина | Решение |
|---|---|---|
| `services.frontend additional properties 'network' not allowed` | Написал `network:` вместо `networks:` | Исправить на `networks:` |
| `volumes must be a mapping` | В верхний `volumes:` попал bind-mount или запись списком | В верхнем `volumes:` только именованные тома (`redis_data:`); bind-mount — в `services.<svc>.volumes` |
| Контейнер `unhealthy`, но приложение в логах работает | Healthcheck бьётся в неверный порт/путь | Проверить порт и путь в `test:`; захардкодить порт вместо `${VAR}` |
| `curl: (7) Failed to connect to localhost port 1` | В healthcheck случайно `$8001` — shell съел `$8` | Убрать лишний `$`: просто `8001` |
| `WARN The "PORT" variable is not set` | `${PORT}` используется, но в `.env` его нет | Либо добавить в `.env`, либо захардкодить значение |
| nginx не стартует, `dependency failed to start` | `depends_on ... condition: service_healthy`, а зависимый сервис `unhealthy` | Понять, почему сервис не проходит healthcheck |

> Подробнее про сети — на отдельной странице: [Сети в Docker Compose](compose-networks.md).

## Best Practices

* **Один сервис = один контейнер.** Не держите несколько процессов в одном контейнере.
* **Держите пароли в `secrets`, не в environment.**
* **Именованные тома для данных**, которые должны пережить рестарт (кэш, БД).
* **Healthcheck у каждого сервиса** + `depends_on` с `condition: service_healthy` для упорядочивания.
* **Используйте `docker compose config`** для валидации до запуска.
* **Масштабируйте через `deploy.replicas`**, а балансировку нагружайте на nginx с динамическим DNS (см. страницу по сетям).
