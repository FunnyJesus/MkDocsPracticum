# Базы данных для DevOps (PostgreSQL)

> Шпаргалка — [PostgreSQL: шпаргалка](postgres-cheatsheet.md). Бэкапы и восстановление в целом — [Бэкапы и DR](backup-dr.md).

DevOps-инженер обычно не пишет SQL-запросы для бизнес-логики, но **отвечает** за то, чтобы база была доступна, забэкаплена, мониторилась и не упиралась в ресурсы. Разберём на примере **PostgreSQL** — самой популярной open-source базы.

## Что входит в зону DevOps

| Задача | Пример |
|---|---|
| Развернуть | managed-сервис в облаке, Docker, оператор в Kubernetes |
| Доступы | пользователи, роли, сетевой доступ (`pg_hba.conf`, security groups) |
| **Бэкапы** | регулярные, проверенные восстановлением |
| Мониторинг | соединения, медленные запросы, репликация, диск |
| Миграции | схема базы обновляется вместе с приложением в CI/CD |
| Масштабирование | реплики для чтения, пул соединений |
| Обновления | минорные — регулярно, мажорные — с планом |

## SQL vs NoSQL: коротко

| Тип | Примеры | Когда |
|---|---|---|
| Реляционные (SQL) | PostgreSQL, MySQL | транзакции, связи между данными — большинство приложений |
| Key-value | Redis, Memcached | кеш, сессии, счётчики |
| Документные | MongoDB | гибкая схема, JSON-документы |
| Временные ряды | Prometheus TSDB, InfluxDB, TimescaleDB | метрики |
| Поисковые | Elasticsearch, OpenSearch | полнотекстовый поиск, логи |

## Запуск для практики

```bash
docker run -d --name pg \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=app \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/data \
  postgres:17

docker exec -it pg psql -U postgres -d app
```

## Подключение: psql

```bash
psql -h localhost -p 5432 -U app -d appdb
psql "postgresql://app:secret@db.example.com:5432/appdb?sslmode=require"
PGPASSWORD=secret psql -h localhost -U app -d appdb -c "select now();"   # в скриптах
```

Пароль для скриптов лучше в `~/.pgpass` (права `600`):

```
db.example.com:5432:appdb:app:secret
```

Мета-команды внутри `psql`:

| Команда | Что делает |
|---|---|
| `\l` | список баз |
| `\c appdb` | переключиться на базу |
| `\dt` | таблицы |
| `\d users` | структура таблицы |
| `\du` | пользователи и роли |
| `\x` | вертикальный вывод (удобно для широких строк) |
| `\timing` | показывать время выполнения |
| `\q` | выйти |

## Пользователи и права

Принцип наименьших привилегий: приложение не должно ходить под `postgres`.

```sql
-- пользователь приложения
CREATE ROLE app WITH LOGIN PASSWORD 'strong-password';
CREATE DATABASE appdb OWNER app;

-- пользователь только на чтение (аналитика, Grafana)
CREATE ROLE readonly WITH LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE appdb TO readonly;
\c appdb
GRANT USAGE ON SCHEMA public TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly;  -- и на будущие таблицы

-- сменить пароль
ALTER ROLE app WITH PASSWORD 'new-password';
```

## Сетевой доступ: pg_hba.conf

Два уровня:

1. `postgresql.conf` → `listen_addresses = '*'` — на каких интерфейсах слушать (по умолчанию только `localhost`).
2. `pg_hba.conf` — **кому** и **как** разрешено подключаться:

```
# TYPE   DATABASE  USER      ADDRESS         METHOD
local    all       postgres                  peer
host     appdb     app       10.0.1.0/24     scram-sha-256
hostssl  appdb     app       0.0.0.0/0       scram-sha-256
host     all       all       0.0.0.0/0       reject
```

```sql
SELECT pg_reload_conf();     -- применить pg_hba.conf без перезапуска
```

> Никогда не открывай 5432 в интернет. Доступ — из приватной сети или через [SSH-туннель](ssh.md).

## Бэкапы

### Логический: pg_dump

Выгружает базу как SQL или в собственном формате. Подходит для баз до десятков ГБ, переносов между версиями.

```bash
# custom-формат (-Fc): сжатый, восстановление выборочно и параллельно
pg_dump -h db -U app -d appdb -Fc -f appdb_$(date +%F).dump

# восстановление
createdb -h db -U postgres appdb_restore
pg_restore -h db -U postgres -d appdb_restore -j 4 appdb_2026-09-26.dump

# простой SQL-формат
pg_dump -h db -U app appdb > appdb.sql
psql -h db -U app -d appdb_restore < appdb.sql

# все базы + роли
pg_dumpall -h db -U postgres > all.sql
```

### Физический: pg_basebackup + WAL

Копия файлов кластера + журнал изменений (**WAL**). Позволяет **восстановиться на любой момент времени** (PITR — Point-In-Time Recovery): «верни базу на 14:32, до того как выполнили DELETE без WHERE».

```bash
pg_basebackup -h db -U replicator -D /backup/base -Ft -z -P
```

На практике используют готовые инструменты: **pgBackRest**, **WAL-G**, **Barman** — они делают полные + инкрементальные бэкапы, архивируют WAL в S3 и восстанавливают на момент времени.

| | pg_dump | pg_basebackup + WAL |
|---|---|---|
| Что | логическая выгрузка | файлы кластера |
| Восстановление на момент времени | нет, только на момент дампа | да (PITR) |
| Скорость на больших базах | медленно | быстро |
| Перенос между мажорными версиями | да | нет |

> **Бэкап, который ни разу не восстанавливали, — не бэкап.** Регулярно делай тестовое восстановление в отдельную базу (автоматически в CI/cron).

## Репликация

**Streaming replication**: основной сервер (**primary**) передаёт WAL на **реплики** (standby).

```
приложение ──запись──► primary ──WAL──► replica 1  ◄──чтение── отчёты, аналитика
                                  └───► replica 2
```

* Реплики — для **чтения** и для **отказоустойчивости** (при падении primary реплику повышают).
* Асинхронная реплика может **отставать** — лаг нужно мониторить.
* Автоматическое переключение (failover) делают **Patroni** (+ etcd/Consul), в Kubernetes — операторы **CloudNativePG**, **Zalando Postgres Operator**.

```sql
-- на primary: состояние реплик
SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;
-- на реплике: я реплика?
SELECT pg_is_in_recovery();
```

## Пул соединений

Каждое соединение в PostgreSQL — отдельный процесс (~5–10 МБ). 50 подов × 20 соединений = 1000 соединений → база задыхается. Решение — **PgBouncer** между приложением и базой: держит немного реальных соединений и раздаёт их клиентам.

```sql
SHOW max_connections;
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
```

## Диагностика

```sql
-- что выполняется прямо сейчас (и как долго)
SELECT pid, usename, state, now() - query_start AS duration, left(query, 80)
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY duration DESC;

-- убить зависший запрос
SELECT pg_cancel_backend(<pid>);       -- мягко отменить запрос
SELECT pg_terminate_backend(<pid>);    -- разорвать соединение

-- кто кого блокирует
SELECT pid, pg_blocking_pids(pid) AS blocked_by, left(query, 60)
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;

-- размер баз и таблиц
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;

-- план запроса
EXPLAIN ANALYZE SELECT * FROM orders WHERE user_id = 42;
```

Медленные запросы — расширение **pg_stat_statements** и `log_min_duration_statement = 500ms` в конфиге.

**VACUUM**: PostgreSQL не удаляет старые версии строк сразу — их чистит `autovacuum`. Если он не справляется, таблицы «раздуваются» (bloat) и запросы замедляются. Мониторь `n_dead_tup` в `pg_stat_user_tables`.

## Мониторинг

Экспортер для Prometheus — **postgres_exporter** (см. [Мониторинг](monitoring.md)). Что смотреть:

| Метрика | Почему важна |
|---|---|
| Число соединений / `max_connections` | исчерпание = приложение не может подключиться |
| Лаг репликации | устаревшие данные на репликах, риск потерь при failover |
| Место на диске | кончилось место = база встала |
| Долгие транзакции | блокируют VACUUM и других |
| Cache hit ratio | < 99% — не хватает памяти (`shared_buffers`) |
| Deadlocks, ошибки | проблемы в логике приложения |

## Миграции схемы в CI/CD

Схема базы меняется вместе с кодом, поэтому миграции — **файлы в репозитории**, которые применяет инструмент: Flyway, Liquibase, Alembic (Python), `migrate` (Go), миграции Django/Rails.

```
migrations/
├── V1__create_users.sql
├── V2__add_email_index.sql
└── V3__add_orders.sql
```

* Запуск — отдельным шагом деплоя (Kubernetes Job, Helm hook `pre-upgrade`, Argo CD `PreSync`).
* **Обратная совместимость**: новая схема должна работать со старой версией кода (во время rolling update работают обе). Удаление колонки — в два релиза: сначала код перестаёт её использовать, потом миграция удаляет.
* Тяжёлые операции (индекс на большой таблице) — `CREATE INDEX CONCURRENTLY`, чтобы не блокировать запись.

## Managed vs self-hosted

| | Managed (RDS, Cloud SQL, Yandex Managed PostgreSQL) | Self-hosted (VM, K8s-оператор) |
|---|---|---|
| Бэкапы, PITR, failover | из коробки | настраивать самому |
| Обновления | по кнопке / автоматически | сам |
| Контроль и расширения | ограничены | полный |
| Цена | дороже | дешевле в деньгах, дороже во времени |

Для большинства команд прод-базу разумнее брать managed (см. [Облака](cloud.md)).

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `FATAL: too many connections` | нет пула, много подов | PgBouncer, лимит пула в приложении |
| `no pg_hba.conf entry for host` | подключение не разрешено | правило в `pg_hba.conf` + `pg_reload_conf()` |
| `Connection refused` снаружи | `listen_addresses = localhost` | настроить `listen_addresses`, firewall |
| Бэкап есть, восстановить не получилось | бэкап не проверялся | регулярное тестовое восстановление |
| Деплой «повесил» базу | миграция держит блокировку на большой таблице | `CONCURRENTLY`, миграции маленькими шагами, `lock_timeout` |
| Диск кончился, база встала | WAL копится (сломанный архив/реплика), bloat | мониторинг диска, слоты репликации, autovacuum |

## Best Practices

* **Бэкап + регулярное тестовое восстановление**, для прода — PITR.
* **Отдельные пользователи** для приложения, миграций и чтения; не `postgres`.
* **База только в приватной сети**, TLS для соединений.
* **Пул соединений** при большом числе клиентов.
* **Миграции в git**, обратно совместимые, отдельным шагом деплоя.
* **Мониторинг** соединений, лага, диска, медленных запросов.
