# Практика: 10 типовых инцидентов

Разбор реальных ситуаций в формате «симптом → диагностика → причина → решение → как предотвратить». Это то, что спрашивают на собеседованиях («что будешь делать, если…»), и то, что случается на первой же неделе дежурств.

> Процесс реагирования — [SRE](sre.md). Команды диагностики — [Linux: диагностика](linux-troubleshooting.md), [K8s: команды](k8s-commands.md).

**Общий порядок для любого инцидента:**

1. **Оценить влияние**: кто пострадал, насколько (всё лежит или часть запросов).
2. **Что менялось?** Последний деплой, изменение конфига, обновление, рост трафика — причина в 70% случаев.
3. **Восстановить** (откат, переключение, масштабирование) — и только потом искать корень.
4. **Записывать действия с временем.**

---

## 1. Под в CrashLoopBackOff

**Симптом:** `kubectl get pods` → `STATUS: CrashLoopBackOff`, `RESTARTS` растёт.

**Диагностика:**

```bash
kubectl describe pod <pod> -n <ns>          # Events, Last State: Terminated, Reason, Exit Code
kubectl logs <pod> -n <ns> --previous       # логи ПРЕДЫДУЩЕГО (упавшего) запуска — главное
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20
```

**Частые причины по Exit Code / Reason:**

| Признак | Причина |
|---|---|
| `Exit Code: 1`, в логах traceback | ошибка приложения: нет переменной окружения, не подключилось к базе, ошибка конфига |
| `Reason: OOMKilled`, `Exit Code: 137` | превышен `limits.memory` |
| `Exit Code: 137` без OOM | убит по SIGKILL — часто **liveness probe** не прошла и kubelet перезапустил |
| `Exit Code: 127` / `exec format error` | нет команды в образе / образ под другую архитектуру (arm64 vs amd64) |
| Контейнер сразу завершается с кодом 0 | процесс не долгоживущий (запускается в фоне, скрипт закончился) |

**Решение:** по причине — исправить конфиг/секрет, поднять лимит памяти (или найти утечку), поправить probe (`initialDelaySeconds`, `startupProbe` для медленного старта), откатить релиз.

**Предотвратить:** проверка конфигурации на старте с понятной ошибкой, `startupProbe`, реалистичные лимиты, smoke-тест после деплоя.

---

## 2. ImagePullBackOff

**Симптом:** под в `ImagePullBackOff` / `ErrImagePull`.

```bash
kubectl describe pod <pod> | grep -A10 Events
# Failed to pull image "registry.example.com/shop:1.4.3": ... not found / unauthorized / toomanyrequests
```

| Сообщение | Причина | Решение |
|---|---|---|
| `not found` / `manifest unknown` | опечатка в имени или теге, образ не запушен (упал CI) | проверить тег в registry |
| `unauthorized` / `authentication required` | нет или неверный `imagePullSecrets` | создать секрет, проверить namespace |
| `toomanyrequests` | лимит Docker Hub | логин, свой registry / pull-through cache |
| `no matching manifest for linux/amd64` | образ собран под другую архитектуру | `docker buildx --platform` |

**Предотвратить:** деплой только после успешного push (зависимость в CI), неизменяемые теги по SHA. См. [Registry](registry.md).

---

## 3. Диск заполнен

**Симптом:** `No space left on device`, база встала, приложение не пишет логи, в K8s — поды `Evicted` с `DiskPressure`.

```bash
df -h                                     # какой раздел
df -i                                     # или кончились inodes
du -xh / --max-depth=2 2>/dev/null | sort -rh | head -20
docker system df                          # на Docker-хосте
journalctl --disk-usage
lsof +L1                                  # удалённые, но открытые файлы
```

**Быстро освободить:**

```bash
journalctl --vacuum-size=500M
docker system prune -af --filter "until=168h"    # образы/контейнеры старше недели
find /var/log -name "*.gz" -mtime +7 -delete
truncate -s 0 /var/log/app/huge.log               # обнулить, а не rm (если файл открыт процессом)
```

**Предотвратить:** logrotate, лимиты логов Docker (`"log-opts": {"max-size": "100m", "max-file": "3"}`), алерт на **прогноз** заполнения (`predict_linear(node_filesystem_avail_bytes[6h], 24*3600) < 0`), retention в registry.

---

## 4. 502 Bad Gateway от Nginx / Ingress

**Симптом:** пользователи видят 502.

```bash
tail -50 /var/log/nginx/error.log
# connect() failed (111: Connection refused) while connecting to upstream   → бэкенд не слушает
# upstream prematurely closed connection                                    → бэкенд упал во время ответа
# no live upstreams                                                         → все бэкенды помечены нерабочими

curl -v http://127.0.0.1:8000/health      # бэкенд отвечает с сервера nginx?
ss -tulpn | grep 8000                      # слушает ли порт, на каком интерфейсе (127.0.0.1 vs 0.0.0.0)
```

В Kubernetes:

```bash
kubectl get endpoints <service> -n <ns>   # пусто? → нет Ready-подов или selector не совпадает с labels
kubectl get pods -l app=<app> -o wide
kubectl describe svc <service>            # targetPort совпадает с containerPort?
```

**Частые причины:** приложение упало; неверный порт в `proxy_pass` / `targetPort`; приложение слушает `127.0.0.1` внутри контейнера вместо `0.0.0.0`; селектор Service не совпадает с метками подов; все поды не прошли readiness.

**Предотвратить:** readiness probe, алерт на 5xx по Ingress, минимум 2 реплики + PodDisruptionBudget.

---

## 5. 504 / всё стало медленным

**Симптом:** латентность выросла в разы, часть запросов — 504 Gateway Timeout.

**Диагностика — идём по цепочке:**

1. Трафик вырос? (дашборд RPS)
2. Какой сервис медленный? — [трейсы](tracing.md), `$upstream_response_time` в логах nginx.
3. Ресурсы: CPU throttling (`container_cpu_cfs_throttled_seconds_total`), память, диск (`iowait`).
4. База: долгие запросы и блокировки (`pg_stat_activity`, см. [Базы данных](databases.md)).
5. Внешние зависимости: API провайдера, DNS.

**Частые причины:** медленный запрос в базе (новый релиз без индекса), исчерпан пул соединений, CPU throttling из-за низкого `limits.cpu`, внешний сервис тормозит без таймаута, «шторм» повторных запросов (retry без backoff).

**Решение:** откат релиза, масштабирование, отмена тяжёлых запросов, circuit breaker / таймауты к внешним API.

---

## 6. DNS не резолвит

**Симптом:** `Could not resolve host`, `Name or service not known`, `i/o timeout` на lookup; в K8s — сервисы не видят друг друга.

```bash
dig api.example.com                       # ответ есть? от какого сервера?
dig @8.8.8.8 api.example.com              # а через публичный DNS?
cat /etc/resolv.conf
```

В Kubernetes:

```bash
kubectl run -it --rm dnstest --image=busybox:1.36 --restart=Never -- nslookup shop.shop.svc.cluster.local
kubectl get pods -n kube-system -l k8s-app=kube-dns          # CoreDNS жив?
kubectl logs -n kube-system -l k8s-app=kube-dns
```

**Частые причины:** опечатка / не тот namespace (`shop` vs `shop.other-ns`); CoreDNS упал или перегружен; NetworkPolicy блокирует UDP/TCP 53 к kube-dns; истёк домен или сломана делегация; кеш DNS со старым IP после переезда (TTL).

**Предотвратить:** мониторинг CoreDNS, разрешить DNS в NetworkPolicy явно, понижать TTL перед миграциями, алерт на срок жизни домена и сертификата.

---

## 7. Истёк TLS-сертификат

**Симптом:** браузер: `NET::ERR_CERT_DATE_INVALID`; сервисы: `x509: certificate has expired`.

```bash
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject
kubectl get certificate -A                # cert-manager: READY=False?
kubectl describe certificate <name> -n <ns>
certbot certificates                      # на сервере с certbot
```

**Частые причины:** не работает автопродление (certbot-таймер выключен, cert-manager не может пройти HTTP-01 challenge из-за редиректа/firewall/DNS), сертификат продлили, но nginx не перечитал его (нет reload), забытый сертификат, выпущенный вручную.

**Решение:** продлить (`certbot renew --force-renewal` / удалить Secret, чтобы cert-manager перевыпустил), `nginx -s reload`.

**Предотвратить:** алерт за 14–21 день до истечения (`probe_ssl_earliest_cert_expiry` из blackbox_exporter), только автоматические сертификаты.

---

## 8. Утечка памяти / OOMKilled

**Симптом:** память пода растёт «пилой»: медленно вверх → OOMKilled → рестарт → снова вверх.

```bash
kubectl describe pod <pod> | grep -A3 "Last State"      # Reason: OOMKilled
kubectl top pod <pod> --containers
dmesg -T | grep -i "killed process"                     # на ноде / сервере
```

Графики `container_memory_working_set_bytes` за несколько дней покажут характер:

* растёт постоянно после каждого деплоя с нуля → **утечка** в коде;
* ступенька после релиза и стабильно → новая версия просто требует больше памяти;
* пики при нагрузке → большие запросы/выборки целиком в память.

**Решение:** временно — поднять лимит и/или перезапускать; по сути — профилирование (heap dump), откат релиза, где появилась утечка. Для JVM — учесть, что `-Xmx` должен быть меньше лимита контейнера.

**Предотвратить:** алерт на рост памяти относительно лимита, нагрузочные тесты, `requests` = реальное потребление, `limits` с запасом.

---

## 9. Деплой сломал прод

**Симптом:** сразу после выкатки выросли ошибки.

**Правило номер один — откатить, а потом разбираться:**

```bash
# Helm
helm history shop -n shop
helm rollback shop <revision> -n shop

# kubectl
kubectl rollout undo deployment/shop -n shop
kubectl rollout status deployment/shop -n shop

# GitOps
git revert <commit> && git push          # Argo CD применит предыдущее состояние
```

**Если откат не помог:** значит, изменилось что-то, что не откатывается кодом — **миграция базы**, конфиг во внешнем сервисе, данные. Поэтому миграции должны быть обратно совместимыми.

**Предотвратить:** canary / blue-green ([CD: стратегии](cd-strategies.md)), автоматический анализ метрик при выкатке (Argo Rollouts, Flagger), `helm upgrade --atomic`, readiness probe, smoke-тесты, feature flags для рискованных изменений.

---

## 10. Кончились соединения к базе

**Симптом:** `FATAL: sorry, too many clients already` / `remaining connection slots are reserved`, приложения падают, часть запросов проходит.

```sql
SHOW max_connections;
SELECT usename, application_name, client_addr, state, count(*)
FROM pg_stat_activity GROUP BY 1,2,3,4 ORDER BY count(*) DESC;

-- соединения, которые давно висят в "idle in transaction" — держат блокировки
SELECT pid, now() - state_change AS idle_for, left(query, 60)
FROM pg_stat_activity WHERE state = 'idle in transaction' ORDER BY idle_for DESC;
```

**Частые причины:** масштабировали приложение (подов × размер пула > `max_connections`); утечка соединений в коде (не возвращаются в пул); «idle in transaction»; миграция/cron открыл много соединений.

**Решение:** закрыть зависшие (`pg_terminate_backend`), уменьшить пул на под / число подов, перезапустить утекающий сервис.

**Предотвратить:** PgBouncer, расчёт `поды × пул < max_connections` с запасом, `idle_in_transaction_session_timeout`, алерт на 80% соединений.

---

## Шпаргалка «куда смотреть первым»

| Симптом | Первая команда |
|---|---|
| Под не стартует | `kubectl describe pod` + `kubectl logs --previous` |
| 5xx от балансировщика | `kubectl get endpoints` / `error.log` nginx |
| Медленно | дашборд RPS/латентности + трейсы + `pg_stat_activity` |
| Сервер тормозит | `uptime`, `top`, `free -h`, `df -h`, `dmesg -T | tail` |
| Не резолвится имя | `dig`, `nslookup` из пода |
| Ошибки сертификата | `openssl s_client ... | openssl x509 -noout -dates` |
| Сломалось после деплоя | откат: `helm rollback` / `rollout undo` / `git revert` |
