# Prometheus и Alertmanager: настройка

> Обзор мониторинга — [Мониторинг и логи](monitoring.md). Визуализация — [Grafana](grafana.md). Быстрые запросы — [Мониторинг: шпаргалка](monitoring-cheatsheet.md).

**Prometheus** — система мониторинга с **pull-моделью**: сам ходит по целям (targets) и забирает метрики по HTTP `GET /metrics`, вместо того чтобы ждать, пока приложение их пришлёт (push). Хранит их как временные ряды и умеет считать по ним алерты.

## Типы метрик

| Тип | Значение | Пример |
|---|---|---|
| **Counter** | Только растёт (или обнуляется при рестарте) | `http_requests_total`, число обработанных запросов |
| **Gauge** | Может расти и падать | `memory_usage_bytes`, число активных соединений |
| **Histogram** | Распределяет наблюдения по «корзинам» (buckets), считает сумму и количество | `http_request_duration_seconds` — сколько запросов уложилось в 0.1с/0.5с/1с |
| **Summary** | Похож на Histogram, но считает перцентили (p50/p90/p99) на стороне клиента | latency с точными квантилями |

> На собеседовании часто спрашивают разницу Counter/Gauge — Counter не может уменьшаться (кроме сброса при рестарте процесса), Gauge может.

Как метрика выглядит в `/metrics`:

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200",service="shop"} 10423
http_requests_total{method="POST",status="500",service="shop"} 17
```

Имя + набор **лейблов** = один **временной ряд**. Каждое уникальное сочетание лейблов — отдельный ряд в памяти Prometheus.

## Архитектура

```
[app :8000/metrics] <--pull-- [Prometheus] --> [Alertmanager] --> Slack/Telegram/Email
[node_exporter :9100/metrics] <--pull--/         |
[cAdvisor :8080/metrics] <--pull--/              v
                                             [Grafana] (читает данные из Prometheus для дашбордов)
```

* **Exporter** — небольшой HTTP-сервис, который отдаёт метрики в формате Prometheus для системы, которая сама так не умеет (`node_exporter` — метрики хоста, `cAdvisor`/`kube-state-metrics` — метрики контейнеров и объектов Kubernetes, `postgres_exporter` — метрики БД, `blackbox_exporter` — проверки HTTP/TCP/ICMP снаружи).
* **Service discovery** — как Prometheus узнаёт, кого «пуллить»: статический список, файлы, Docker/Kubernetes SD (автоматически находит поды по лейблам).
* **scrape_interval** — как часто опрашивать цели (обычно 15–30с).

Файлы, с которыми работаем:

```
prometheus/
├── prometheus.yml          # что и как собирать, куда слать алерты
├── rules/
│   ├── recording.yml       # предрасчитанные запросы
│   └── alerts.yml          # правила алертов
├── targets/
│   └── nodes.yml           # цели для file_sd (можно менять без перезапуска)
└── tests/
    └── alerts_test.yml     # unit-тесты правил
alertmanager/
└── alertmanager.yml        # куда и как отправлять уведомления
```

## prometheus.yml

### Минимальный

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "order-service"
    static_configs:
      - targets: ["order-service:8000"]

  - job_name: "node"
    static_configs:
      - targets: ["node-exporter:9100"]
```

### Полный (с разбором)

```yaml
global:
  scrape_interval: 15s          # как часто собирать метрики (по умолчанию 1m)
  scrape_timeout: 10s           # таймаут одного опроса (меньше scrape_interval)
  evaluation_interval: 15s      # как часто вычислять правила (recording/alerts)
  external_labels:              # добавляются ко всем метрикам при отправке наружу
    cluster: prod               # (remote_write, федерация, алерты) — видно, откуда пришло
    region: eu-1

# файлы с правилами (glob-маски можно)
rule_files:
  - /etc/prometheus/rules/*.yml

# куда отправлять сработавшие алерты
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  # 1. сам Prometheus
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # 2. статический список + свои лейблы
  - job_name: node
    static_configs:
      - targets: ["node1:9100", "node2:9100"]
        labels:
          env: prod
          role: web

  # 3. приложение с нестандартным путём, HTTPS и авторизацией
  - job_name: shop
    metrics_path: /internal/metrics
    scheme: https
    scrape_interval: 30s        # можно переопределить для job
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/secrets/shop_password
    tls_config:
      insecure_skip_verify: false
    static_configs:
      - targets: ["shop.example.com:443"]

  # 4. цели из файлов — Ansible/скрипт пишет файл, Prometheus перечитывает сам
  - job_name: file-sd
    file_sd_configs:
      - files: ["/etc/prometheus/targets/*.yml"]
        refresh_interval: 1m
```

`targets/nodes.yml` для file_sd:

```yaml
- targets: ["10.0.1.11:9100", "10.0.1.12:9100"]
  labels:
    env: prod
    dc: msk
- targets: ["10.0.2.21:9100"]
  labels:
    env: staging
```

### Автоматические лейблы

К каждой метрике Prometheus сам добавляет:

| Лейбл | Откуда |
|---|---|
| `job` | `job_name` из конфига |
| `instance` | адрес цели (`host:port`) |

Плюс служебная метрика `up{job, instance}` = 1, если опрос успешен, и 0, если нет — основа алерта «сервис недоступен».

## Relabeling

**Relabeling** — изменение лейблов по правилам. Два места:

| Где | Когда | Для чего |
|---|---|---|
| `relabel_configs` | **до** опроса цели | выбрать цели, поменять адрес/путь, превратить метаданные SD в лейблы |
| `metric_relabel_configs` | **после** опроса, до записи | выкинуть лишние метрики/лейблы, сэкономить память |

Действия (`action`):

| action | Что делает |
|---|---|
| `replace` (по умолчанию) | записать значение (с regex-подстановкой) в `target_label` |
| `keep` | оставить только цели/метрики, где regex совпал |
| `drop` | выкинуть, где regex совпал |
| `labelmap` | скопировать лейблы по шаблону имени |
| `labeldrop` / `labelkeep` | удалить / оставить лейблы по имени |

Лейблы, начинающиеся с `__`, — служебные: `__address__` (куда ходить), `__metrics_path__`, `__scheme__`, `__param_<name>`, `__meta_*` (метаданные service discovery). После relabeling они удаляются.

### Kubernetes: поды с аннотациями

Классический способ без оператора — собирать поды, у которых есть аннотация `prometheus.io/scrape: "true"`:

```yaml
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod                   # также: node, service, endpoints, endpointslice, ingress
    relabel_configs:
      # оставить только поды с prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # путь из аннотации prometheus.io/path (если есть)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        regex: (.+)
        target_label: __metrics_path__
      # порт из аннотации prometheus.io/port
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # все метки пода → лейблы метрик
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      # namespace и имя пода
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

Под:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"
    prometheus.io/path: "/metrics"
```

> `source_labels` из нескольких лейблов склеиваются через `;` — поэтому в regex для порта стоит `;`.

### Blackbox exporter: проверка сайтов снаружи

```yaml
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]            # модуль из конфига blackbox_exporter
    static_configs:
      - targets:
          - https://example.com
          - https://api.example.com/health
    relabel_configs:
      - source_labels: [__address__]      # URL цели → параметр ?target=
        target_label: __param_target
      - source_labels: [__param_target]   # URL → лейбл instance (для читаемости)
        target_label: instance
      - target_label: __address__         # а реально ходим в сам blackbox_exporter
        replacement: blackbox-exporter:9115
```

Метрики: `probe_success`, `probe_duration_seconds`, `probe_http_status_code`, `probe_ssl_earliest_cert_expiry`.

### Выкинуть лишнее (экономия памяти)

```yaml
  - job_name: shop
    static_configs:
      - targets: ["shop:8000"]
    metric_relabel_configs:
      - source_labels: [__name__]           # метрики Go-рантайма не нужны
        regex: go_gc_.*|go_memstats_.*
        action: drop
      - regex: request_id                   # лейбл с уникальным значением — убийца памяти
        action: labeldrop
```

> **Кардинальность** — число уникальных временных рядов. Лейбл с `user_id`, `request_id`, полным URL с ID — это миллионы рядов и упавший по памяти Prometheus. Такие данные — в логи и трейсы, не в метрики.

## Recording rules

**Recording rule** — заранее посчитанный тяжёлый запрос, сохраняемый как новая метрика. Дашборды и алерты работают быстрее.

```yaml
# rules/recording.yml
groups:
  - name: http-recording
    interval: 30s                  # можно переопределить evaluation_interval
    rules:
      # соглашение об именах: уровень:метрика:операция
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      - record: job:http_errors:ratio_rate5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (job) (rate(http_requests_total[5m]))

      - record: job:http_request_duration_seconds:p99_5m
        expr: histogram_quantile(0.99, sum by (job, le) (rate(http_request_duration_seconds_bucket[5m])))
```

## Alert rules

```yaml
# rules/alerts.yml
groups:
  - name: availability
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m                                    # держится 2 минуты — только тогда firing
        labels:
          severity: critical
        annotations:
          summary: "Инстанс {{ $labels.instance }} недоступен"
          runbook_url: "https://wiki.example.com/runbooks/instance-down"

      - alert: HighErrorRate
        expr: job:http_errors:ratio_rate5m > 0.05  # используем recording rule
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }}: доля 5xx {{ $value | humanizePercentage }}"
          description: "Больше 5% ответов с ошибкой уже 10 минут."
          runbook_url: "https://wiki.example.com/runbooks/high-error-rate"

  - name: resources
    rules:
      - alert: DiskWillFillIn24h
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24 * 3600) < 0
          and
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.2
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} {{ $labels.mountpoint }}: диск заполнится за сутки"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: занято {{ $value | humanizePercentage }} памяти"

      - alert: SSLCertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 14 * 24 * 3600
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Сертификат {{ $labels.instance }} истекает через {{ $value | humanizeDuration }}"
```

| Поле | Зачем |
|---|---|
| `expr` | PromQL: алерт активен, пока запрос возвращает хоть один ряд |
| `for` | защита от «дребезга»: без него алерт срабатывал бы на каждый случайный всплеск в одну точку |
| `labels` | для маршрутизации в Alertmanager (`severity`, `team`) |
| `annotations` | текст для человека; `{{ $labels.x }}`, `{{ $value }}` — шаблоны |
| `runbook_url` | ссылка «что делать» — см. [SRE: runbook](sre.md) |

Состояния алерта: **inactive** → **pending** (условие выполняется, но `for` ещё не прошёл) → **firing** (отправлен в Alertmanager).

### Unit-тесты правил

```yaml
# tests/alerts_test.yml
rule_files:
  - ../rules/alerts.yml

evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      - series: 'up{job="node", instance="n1"}'
        values: "1 0 0 0 0"             # минута 0: жив, с 1-й минуты — лежит
    alert_rule_test:
      - eval_time: 4m
        alertname: InstanceDown
        exp_alerts:
          - exp_labels:
              severity: critical
              job: node
              instance: n1
            exp_annotations:
              summary: "Инстанс n1 недоступен"
              runbook_url: "https://wiki.example.com/runbooks/instance-down"
```

```bash
promtool test rules tests/alerts_test.yml
```

## PromQL — язык запросов

```promql
# Текущее значение метрики
http_requests_total

# Скорость роста counter'а за 5 минут (запросов в секунду)
rate(http_requests_total[5m])

# Топ-5 самых нагруженных сервисов
topk(5, sum by (service) (rate(http_requests_total[5m])))

# 99-й перцентиль латентности по гистограмме
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))

# Доля ошибок 5xx
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
```

> `rate()` обязателен для counter'ов — сырое значение бесполезно (оно просто «сколько всего было с запуска»), важна именно скорость изменения.

Селекторы лейблов: `=` равно, `!=` не равно, `=~` regex, `!~` не regex. Больше запросов — в [шпаргалке](monitoring-cheatsheet.md).

## alertmanager.yml

Prometheus решает, **что** горит, Alertmanager — **кому, куда и как часто** сообщить: группирует, убирает дубли, глушит.

```yaml
global:
  resolve_timeout: 5m

# шаблоны сообщений (необязательно)
templates:
  - /etc/alertmanager/templates/*.tmpl

route:                                 # корневой маршрут — обязателен
  receiver: default                    # куда идёт всё, что не подошло ниже
  group_by: [alertname, cluster, job]  # алерты с одинаковыми значениями — одним сообщением
  group_wait: 30s                      # подождать перед первой отправкой группы (собрать соседей)
  group_interval: 5m                   # не чаще, чем раз в 5м, слать изменения в группе
  repeat_interval: 4h                  # напоминать о неисправленном раз в 4 часа
  routes:                              # дочерние маршруты, проверяются по порядку
    - matchers:
        - severity = "critical"
      receiver: oncall-telegram
      continue: true                   # после совпадения проверять и следующие маршруты
    - matchers:
        - team = "db"
      receiver: db-slack
    - matchers:
        - alertname = "Watchdog"       # «алерт жизни» — всегда горит, проверка, что цепочка работает
      receiver: "null"

receivers:
  - name: default
    email_configs:
      - to: devops@example.com
        from: alertmanager@example.com
        smarthost: smtp.example.com:587
        auth_username: alertmanager@example.com
        auth_password_file: /etc/alertmanager/secrets/smtp_password
        send_resolved: true

  - name: oncall-telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/telegram_token
        chat_id: -1001234567890
        parse_mode: HTML
        send_resolved: true

  - name: db-slack
    slack_configs:
      - api_url_file: /etc/alertmanager/secrets/slack_webhook
        channel: "#db-alerts"
        send_resolved: true
        title: '{{ .CommonLabels.alertname }} ({{ .Status }})'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ "\n" }}{{ end }}'

  - name: "null"                       # «никуда»

# подавление: если горит critical, не слать warning по тому же инстансу
inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: [alertname, instance]
```

> Секреты (токены ботов, webhook-и, пароли SMTP) — через `*_file`, а не прямо в YAML, который лежит в git. См. [Секреты](secrets.md).

**Silence** (заглушка) — временно не слать алерты по фильтру, например на время плановых работ: в UI Alertmanager (`:9093`) или `amtool silence add`.

## Проверка и применение

```bash
promtool check config prometheus.yml             # синтаксис конфига и файлов правил
promtool check rules rules/*.yml                 # только правила
promtool test rules tests/*.yml                  # unit-тесты правил
amtool check-config alertmanager.yml             # конфиг Alertmanager

# перечитать конфиг без перезапуска
kill -HUP $(pidof prometheus)
curl -X POST http://localhost:9090/-/reload      # нужен флаг --web.enable-lifecycle
curl -X POST http://localhost:9093/-/reload      # Alertmanager

# проверить, что цели видны
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError)"'
```

В UI Prometheus (`:9090`): **Status → Targets** (что собирается и ошибки), **Status → Configuration** (итоговый конфиг), **Alerts** (состояние правил), **Status → Service Discovery** (лейблы до и после relabeling — незаменимо при отладке).

## Флаги запуска

| Флаг | Зачем |
|---|---|
| `--config.file=/etc/prometheus/prometheus.yml` | путь к конфигу |
| `--storage.tsdb.path=/prometheus` | где хранить данные (том!) |
| `--storage.tsdb.retention.time=15d` | сколько хранить (по умолчанию 15d) |
| `--storage.tsdb.retention.size=50GB` | или лимит по размеру |
| `--web.enable-lifecycle` | разрешить `/-/reload` по HTTP |
| `--web.external-url=https://prometheus.example.com` | внешний адрес (для ссылок в алертах) |

Долгое хранение и много кластеров — `remote_write` в **Thanos**, **Grafana Mimir** или **VictoriaMetrics**:

```yaml
remote_write:
  - url: http://victoriametrics:8428/api/v1/write
```

## Kubernetes: kube-prometheus-stack

В Kubernetes Prometheus обычно ставят Helm-чартом **kube-prometheus-stack** (Prometheus Operator + Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + готовые дашборды и алерты).

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f values-monitoring.yaml
```

Вместо правки `prometheus.yml` — **CRD**:

### ServiceMonitor — что собирать

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: shop
  namespace: shop
  labels:
    release: kps                # по умолчанию Prometheus берёт ServiceMonitor-ы с меткой релиза
spec:
  selector:
    matchLabels:
      app: shop                 # метки Service (не подов!)
  namespaceSelector:
    matchNames: [shop]
  endpoints:
    - port: http                # ИМЯ порта в Service, не номер
      path: /metrics
      interval: 30s
```

`PodMonitor` — то же, но напрямую по подам без Service.

### PrometheusRule — правила

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: shop-alerts
  namespace: shop
  labels:
    release: kps
spec:
  groups:
    - name: shop
      rules:
        - alert: ShopHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="shop",status=~"5.."}[5m]))
            / sum(rate(http_requests_total{namespace="shop"}[5m])) > 0.05
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "shop: доля 5xx выше 5%"
```

### values для чарта (фрагмент)

```yaml
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 50Gi
    # брать ServiceMonitor/PrometheusRule из всех namespace и без метки release
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

alertmanager:
  config:
    route:
      receiver: telegram
      group_by: [alertname, namespace]
    receivers:
      - name: telegram
        telegram_configs:
          - bot_token_file: /etc/alertmanager/secrets/alertmanager-telegram/token
            chat_id: -1001234567890
  alertmanagerSpec:
    secrets: [alertmanager-telegram]      # Secret смонтируется в /etc/alertmanager/secrets/<имя>/
```

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Цель `DOWN`: `connection refused` | не тот порт/хост, exporter не запущен | `curl <target>/metrics` с машины Prometheus |
| Цель `DOWN`: `context deadline exceeded` | `/metrics` отвечает дольше `scrape_timeout` | ускорить exporter, увеличить таймаут |
| ServiceMonitor есть, целей нет | нет метки `release`, `port` указан номером, не совпали метки Service | `serviceMonitorSelectorNilUsesHelmValues: false`, имя порта, метки |
| Prometheus съел всю память | высокая кардинальность (ID в лейблах) | `metric_relabel_configs` + `labeldrop`, чинить инструментирование |
| Алерт не приходит, а в Prometheus firing | маршрут в Alertmanager не совпал / ошибка ресивера | UI Alertmanager, `amtool config routes test severity=critical`, логи Alertmanager |
| Приходит 50 сообщений на одну аварию | нет `group_by` / `inhibit_rules` | группировка и подавление |
| Изменения конфига не применились | не сделали reload или конфиг невалиден | `promtool check config` → `/-/reload`, смотреть логи |

## Best Practices

* **`promtool check` и `promtool test rules` в CI** для репозитория с конфигами.
* **Recording rules** для всего, что используется в дашбордах и алертах часто.
* **Алерты с `for`, `severity` и `runbook_url`.**
* **Следи за кардинальностью**: `topk(10, count by (__name__) ({__name__=~".+"}))` — кто занимает больше всего рядов.
* **Watchdog-алерт** (всегда горит) + внешний «dead man's switch» — узнаешь, что сломался сам мониторинг.
* **Секреты через `*_file`**, конфиги — в git.
