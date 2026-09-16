# Мониторинг: шпаргалка

Быстрые запросы и команды для Prometheus, Grafana, логов.

> Теория — [Мониторинг и логирование](monitoring.md).

## PromQL

| # | Запрос | Что делает |
|---|---|---|
| 1 | `up` | какие targets сейчас доступны (1) / недоступны (0) |
| 2 | `rate(http_requests_total[5m])` | скорость роста counter'а за 5 минут |
| 3 | `sum by (service) (rate(http_requests_total[5m]))` | RPS по сервисам |
| 4 | `topk(5, ...)` | топ-5 значений |
| 5 | `histogram_quantile(0.99, rate(x_bucket[5m]))` | p99 по гистограмме |
| 6 | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` | доля ошибок 5xx |
| 7 | `increase(http_requests_total[1h])` | сколько запросов пришло за час (не скорость, а разница) |
| 8 | `avg_over_time(cpu_usage[10m])` | среднее значение gauge за период |
| 9 | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` | доля свободной памяти (node_exporter) |
| 10 | `count(up == 0)` | сколько targets сейчас недоступно |

## Проверка /metrics и API

```bash
# посмотреть сырые метрики приложения
curl -s http://localhost:8000/metrics | head -30

# статус целей Prometheus
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'

# выполнить PromQL через API
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq
```

## Alertmanager (amtool)

```bash
amtool alert query                     # текущие активные алерты
amtool silence add alertname=HighCPU   # заглушить алерт
amtool silence query                   # список заглушек
```

## Логи

```bash
docker logs -f <container>                       # логи контейнера в реальном времени
docker logs --tail 100 <container>                # последние 100 строк
kubectl logs -f pod/<name>                        # логи пода
kubectl logs -f deployment/<name> --all-containers
kubectl logs pod/<name> --previous                # логи упавшего контейнера до рестарта

# фильтрация логов по ключевым словам
docker logs app 2>&1 | grep -i error
```

## Grafana / общее

* **Data source** → **Dashboard** → **Panel** (с PromQL-запросом внутри).
* Explore-режим в Grafana — быстрый ad-hoc запрос без создания дашборда.
* Переменные дашборда: `$service`, `$instance` — один дашборд на все сервисы.

> Подробности типов метрик, Alertmanager-правил и логирования — в теории: [Мониторинг и логирование](monitoring.md).
