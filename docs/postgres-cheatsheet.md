# PostgreSQL: шпаргалка

Самое частое для DevOps: подключиться, выдать доступ, забэкапить, найти проблему.

> Теория — [Базы данных (PostgreSQL)](databases.md).

## Топ-20

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | подключение | `psql -h host -U user -d db` | подключиться |
| 2 | подключение | `psql "postgresql://user:pass@host:5432/db"` | подключиться строкой (URI) |
| 3 | подключение | `psql -c "select 1"` | выполнить запрос и выйти |
| 4 | psql | `\l`, `\c db`, `\dt`, `\d table`, `\du` | базы, переключиться, таблицы, структура, роли |
| 5 | psql | `\x` / `\timing` | вертикальный вывод / время запроса |
| 6 | доступ | `CREATE ROLE app LOGIN PASSWORD '...';` | создать пользователя |
| 7 | доступ | `CREATE DATABASE appdb OWNER app;` | создать базу |
| 8 | доступ | `GRANT SELECT ON ALL TABLES IN SCHEMA public TO ro;` | права на чтение |
| 9 | доступ | `SELECT pg_reload_conf();` | применить `pg_hba.conf` / конфиг |
| 10 | бэкап | `pg_dump -Fc -d db -f db.dump` | логический бэкап (custom-формат) |
| 11 | бэкап | `pg_restore -d newdb -j 4 db.dump` | восстановление в 4 потока |
| 12 | бэкап | `pg_dumpall > all.sql` | все базы и роли |
| 13 | бэкап | `pg_basebackup -D /backup -Ft -z -P` | физическая копия кластера |
| 14 | диагностика | `SELECT * FROM pg_stat_activity WHERE state <> 'idle';` | активные запросы |
| 15 | диагностика | `SELECT pg_cancel_backend(pid);` / `pg_terminate_backend(pid)` | отменить запрос / разорвать соединение |
| 16 | диагностика | `SELECT pid, pg_blocking_pids(pid) FROM pg_stat_activity;` | кто кого блокирует |
| 17 | диагностика | `EXPLAIN ANALYZE <запрос>;` | реальный план и время запроса |
| 18 | размер | `SELECT pg_size_pretty(pg_database_size('db'));` | размер базы |
| 19 | репликация | `SELECT * FROM pg_stat_replication;` | состояние реплик (на primary) |
| 20 | репликация | `SELECT pg_is_in_recovery();` | это реплика? |

## Бэкап по cron с ротацией

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR=/backup/pg
FILE="$DIR/appdb_$(date +%F_%H%M).dump"

pg_dump -h db.internal -U backup -d appdb -Fc -f "$FILE"
find "$DIR" -name "appdb_*.dump" -mtime +7 -delete     # хранить 7 дней
# + скопировать в S3 / другое место: бэкап на том же сервере — не бэкап
```

```
# crontab -e
0 3 * * * /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1
```

## Быстрая диагностика

```sql
-- соединения по состоянию
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;

-- самые долгие активные запросы
SELECT pid, now() - query_start AS dur, left(query, 80)
FROM pg_stat_activity WHERE state = 'active' ORDER BY dur DESC LIMIT 5;

-- топ-10 таблиц по размеру
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;
```
