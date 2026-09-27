# Мониторинг и логирование

**Мониторинг** — постоянное наблюдение за состоянием системы (жива ли, отвечает ли, не перегружена ли), чтобы узнать о проблеме раньше пользователя, а не из его жалобы.

Подразделы с настройкой конкретных инструментов:

| Раздел | Что внутри |
|---|---|
| [Prometheus и Alertmanager](prometheus.md) | типы метрик, `prometheus.yml`, service discovery и relabeling, recording/alert rules и их тесты, `alertmanager.yml`, ServiceMonitor/PrometheusRule |
| [Grafana](grafana.md) | `grafana.ini` и `GF_*`, provisioning источников и дашбордов, JSON дашборда, алерты, sidecar в Kubernetes |
| [Vector](vector.md) | сбор логов: sources/transforms/sinks, VRL, конфиги для Docker/K8s/journald, отправка в Loki/Elasticsearch/S3, тесты |
| [Трейсинг и OpenTelemetry](tracing.md) | trace/span, OTel Collector, Jaeger/Tempo, sampling |
| [Шпаргалка](monitoring-cheatsheet.md) | PromQL, LogQL, команды promtool/amtool/vector |

## Три кита observability

| Компонент | Отвечает на вопрос | Инструменты |
|---|---|---|
| **Metrics (метрики)** | Что происходит численно прямо сейчас? (CPU, RPS, latency) | Prometheus, Grafana |
| **Logs (логи)** | Что именно произошло в конкретный момент? | Vector/Fluent Bit + Loki или ELK |
| **Traces (трейсы)** | Как запрос прошёл через цепочку сервисов? | OpenTelemetry, Jaeger, Tempo |

> Метрики говорят «латентность выросла в 22:14», логи — «в 22:14 сервис order-service упал с NullPointerException», трейс — «запрос завис на вызове к redis». По отдельности каждый даёт часть картины, вместе — полную.

## Общая схема стека

```
                 ┌──────────── метрики (pull) ────────────┐
 [app /metrics]  │                                        ▼
 [node_exporter] ┼──────────────────────────────►  [Prometheus] ──► [Alertmanager] ──► Telegram/Slack/Email
 [blackbox]      │                                        │
                 │                                        ▼
 [stdout / файлы / journald] ──► [Vector] ──► [Loki] ──► [Grafana] ◄── [Tempo] ◄── [OTel Collector] ◄── трейсы
```

| Инструмент | Роль | Подробно |
|---|---|---|
| **Prometheus** | собирает и хранит метрики, вычисляет правила алертов | [Prometheus](prometheus.md) |
| **Exporters** | отдают метрики систем, которые не умеют сами (хост, БД, Nginx) | [Prometheus](prometheus.md) |
| **Alertmanager** | группирует алерты и отправляет уведомления | [Prometheus](prometheus.md) |
| **Grafana** | дашборды и Explore поверх метрик, логов и трейсов | [Grafana](grafana.md) |
| **Vector** | собирает, разбирает и отправляет логи | [Vector](vector.md) |
| **Loki** | хранилище логов с индексом по лейблам | ниже |
| **Tempo / Jaeger** | хранилище трейсов | [Трейсинг](tracing.md) |

## Метрики: коротко

**Prometheus** работает по **pull-модели**: сам раз в `scrape_interval` ходит на `GET /metrics` каждой цели. Типы метрик — Counter, Gauge, Histogram, Summary; запросы пишутся на **PromQL**; алерты — правила с `expr` и `for`, уведомления рассылает Alertmanager. Всё это с примерами конфигов — в разделе [Prometheus и Alertmanager](prometheus.md).

## Логирование

Централизованное логирование нужно, потому что при масштабировании (много реплик, много подов) логи каждого контейнера по отдельности бесполезны — их нужно собрать в одном месте и уметь искать.

Конвейер логов всегда из трёх частей:

| Часть | Что делает | Примеры |
|---|---|---|
| **Агент / сборщик** | читает логи на хосте/ноде, разбирает, отправляет | **Vector**, Fluent Bit, Fluentd, Filebeat, Grafana Alloy |
| **Хранилище** | хранит и ищет | **Loki**, Elasticsearch/OpenSearch, ClickHouse |
| **UI** | поиск и визуализация | **Grafana** (для Loki), Kibana (для Elasticsearch) |

### Стек ELK / EFK

| Компонент | Роль |
|---|---|
| **Filebeat / Fluentd / Fluent Bit / Vector** | агент на каждом хосте/поде, читает логи и отправляет дальше |
| **Logstash** | обработка и трансформация логов (парсинг, фильтры) — тяжелее остальных |
| **Elasticsearch** | хранение и полнотекстовый поиск по логам |
| **Kibana** | UI для поиска и визуализации логов |

### Стек Loki (более лёгкая альтернатива)

* **Vector** (или Grafana Alloy, Fluent Bit) — агент сбора логов. Раньше для Loki использовали **Promtail**, но Grafana объявила его устаревшим в пользу Alloy.
* **Loki** — хранилище логов от Grafana Labs. В отличие от Elasticsearch, **не индексирует полный текст**, а индексирует только **лейблы** (как Prometheus), а сам текст лога хранит сжатым. Из-за этого дешевле по ресурсам.
* **Grafana** — тот же UI, что и для метрик: можно смотреть метрику и рядом логи за тот же период в одном интерфейсе.

Запросы к Loki — на **LogQL**:

```logql
{service="shop", level="error"}                       # поток по лейблам
{service="shop"} |= "timeout"                         # строки, содержащие timeout
{service="shop"} | json | status >= 500               # разобрать JSON и фильтровать по полю
sum by (service) (rate({env="prod"} |= "error" [5m])) # метрика из логов: ошибок в секунду
```

Настройка сборщика с примерами конфигов — [Vector](vector.md).

### Логи на месте

```bash
# логи контейнера
docker logs -f order-service

# логи пода в Kubernetes
kubectl logs -f pod/order-service-abc123
kubectl logs -f deployment/order-service --all-containers

# логи предыдущего (упавшего) контейнера — если под перезапустился
kubectl logs pod/order-service-abc123 --previous
```

> Логи контейнера в Docker/K8s по умолчанию — это то, что процесс пишет в **stdout/stderr**. Приложение не должно писать логи в файл внутри контейнера — их потеряет при пересоздании контейнера.

## SLI / SLO / SLA / Error Budget

Термины, которые часто спрашивают на собеседованиях — и которые тестировщику концептуально близки (это тоже про «критерии качества»):

| Термин | Значение | Пример |
|---|---|---|
| **SLI** (Service Level Indicator) | Измеримая метрика качества | Доля успешных запросов, latency p99 |
| **SLO** (Service Level Objective) | Внутренняя цель по SLI | «p99 latency < 300мс в 99.9% времени» |
| **SLA** (Service Level Agreement) | Договор с последствиями (штрафы) при нарушении | «Доступность 99.9% или возврат оплаты» |
| **Error budget** | Допустимый «бюджет» нарушений SLO за период | Если SLO 99.9% — бюджет 43 минуты простоя в месяц |

> Error budget — практичная идея: пока бюджет не исчерпан, команда может рисковать (катить фичи быстрее); когда исчерпан — приоритет смещается на стабильность. Подробнее и про алерты по burn rate — [SRE](sre.md).

## Учебный стенд: всё вместе в Docker Compose

Метрики хоста и контейнеров, алерты, логи всех контейнеров и Grafana с готовыми источниками — одной командой. Конфиги каждого сервиса разобраны в подразделах.

```
monitoring-lab/
├── docker-compose.yml
├── prometheus/
│   ├── prometheus.yml
│   └── rules/alerts.yml
├── alertmanager/
│   └── alertmanager.yml
├── vector/
│   └── vector.yaml
└── grafana/
    ├── provisioning/
    │   ├── datasources/datasources.yaml
    │   └── dashboards/dashboards.yaml
    └── dashboards/
        └── node-exporter.json          # скачать с grafana.com (ID 1860)
```

```yaml
# docker-compose.yml
# версии — ориентир, проверь актуальные и зафиксируй
services:
  prometheus:
    image: prom/prometheus:v3.0.0
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=7d
      - --web.enable-lifecycle
    ports: ["9090:9090"]
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus-data:/prometheus

  alertmanager:
    image: prom/alertmanager:v0.27.0
    command: [--config.file=/etc/alertmanager/alertmanager.yml]
    ports: ["9093:9093"]
    volumes:
      - ./alertmanager:/etc/alertmanager:ro

  node-exporter:
    image: prom/node-exporter:v1.8.2
    command: [--path.rootfs=/host]
    pid: host
    volumes:
      - /:/host:ro,rslave

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  loki:
    image: grafana/loki:3.2.0          # запускается со встроенным local-config
    ports: ["3100:3100"]

  vector:
    image: timberio/vector:0.42.0-alpine
    volumes:
      - ./vector/vector.yaml:/etc/vector/vector.yaml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - vector-data:/var/lib/vector
    depends_on: [loki]

  grafana:
    image: grafana/grafana:11.3.0
    ports: ["3000:3000"]
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin   # только для локального стенда!
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    depends_on: [prometheus, loki]

volumes:
  prometheus-data:
  grafana-data:
  vector-data:
```

`prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files: [/etc/prometheus/rules/*.yml]

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: prometheus
    static_configs: [{ targets: ["localhost:9090"] }]
  - job_name: node
    static_configs: [{ targets: ["node-exporter:9100"] }]
  - job_name: cadvisor
    static_configs: [{ targets: ["cadvisor:8080"] }]
  - job_name: vector
    static_configs: [{ targets: ["vector:9598"] }]
```

`prometheus/rules/alerts.yml`, `alertmanager/alertmanager.yml` — примеры в [Prometheus](prometheus.md).

`vector/vector.yaml`:

```yaml
data_dir: /var/lib/vector

sources:
  docker:
    type: docker_logs
    exclude_containers: [vector]
  vector_metrics:
    type: internal_metrics

transforms:
  parse:
    type: remap
    inputs: [docker]
    source: |
      parsed, err = parse_json(.message)
      if err == null && is_object(parsed) { . = merge(., object!(parsed)) }
      .service = .label."com.docker.compose.service" || .container_name
      .level = downcase(string(.level) ?? "info")

sinks:
  loki:
    type: loki
    inputs: [parse]
    endpoint: http://loki:3100
    encoding: { codec: json }
    labels:
      service: "{{ service }}"
      level: "{{ level }}"
  prom:
    type: prometheus_exporter
    inputs: [vector_metrics]
    address: 0.0.0.0:9598
```

`grafana/provisioning/datasources/datasources.yaml`:

```yaml
apiVersion: 1
datasources:
  - { name: Prometheus, uid: prometheus, type: prometheus, access: proxy, url: "http://prometheus:9090", isDefault: true }
  - { name: Loki, uid: loki, type: loki, access: proxy, url: "http://loki:3100" }
```

`grafana/provisioning/dashboards/dashboards.yaml` — провайдер из раздела [Grafana](grafana.md) (путь `/var/lib/grafana/dashboards`).

```bash
docker compose up -d
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Prometheus:   http://localhost:9090  → Status → Targets: все UP
# Alertmanager: http://localhost:9093
# Grafana:      http://localhost:3000  (admin / admin) → Explore → Loki: {service="loki"}
```

Что попробовать на стенде:

* остановить `node-exporter` → через 2 минуты алерт `InstanceDown` в Alertmanager;
* в Grafana Explore → Loki: `{service="prometheus"} |= "error"`;
* импортировать дашборд Node Exporter Full и посмотреть на свой хост;
* добавить своё приложение с `/metrics` в `scrape_configs`.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Алерт молчит, инцидент никто не заметил | Нет алерта на симптом (только на причину) или алерт слишком узкий | Алертить на пользовательские симптомы (error rate, latency), а не только на «CPU > 80%» |
| Alert fatigue — все игнорируют алерты | Слишком много шумных/неактуальных алертов | Меньше алертов, но по делу; `for:` против дребезга; группировка в Alertmanager |
| Дашборд показывает «всё зелёное», а пользователи жалуются | Метрики берутся со стороны сервера, а не клиента | Добавить RUM/synthetic-мониторинг (blackbox_exporter), смотреть latency с точки зрения клиента |
| Логи «потерялись» после падения пода | Логи писались в файл внутри контейнера, а не в stdout | Логировать в stdout/stderr, собирать агентом снаружи |
| Prometheus не видит новый под | Нет нужных лейблов/аннотаций для service discovery | Проверить `prometheus.io/scrape` аннотации или ServiceMonitor — см. [Prometheus](prometheus.md) |
| Loki/Prometheus упёрлись в память | Высокая кардинальность: ID в лейблах | ID — в тело лога/трейсы, в лейблах только низкокардинальные значения |

## Best Practices

* **Мониторь симптомы, а не только причины.** Latency и error rate важнее, чем «CPU вырос» — CPU может расти и без проблем для пользователя.
* **RED-метрики для сервисов:** Rate (запросов/сек), Errors (ошибок/сек), Duration (латентность).
* **USE-метрики для ресурсов:** Utilization, Saturation, Errors (CPU, диск, сеть).
* **Используй пробы Kubernetes вместе с мониторингом** — readiness/liveness (см. [Kubernetes](k8s.md)) реагируют мгновенно локально, мониторинг видит картину по всей системе.
* **Не логируй секреты** (пароли, токены) — они улетят в общее хранилище логов, которое читает больше людей, чем стоило бы.
* **Держи alerting actionable** — если на алерт непонятно, что делать, это плохой алерт.
* **Конфиги мониторинга — в git**, проверки (`promtool`, `vector validate`) — в CI.
