# Vector: сбор и обработка логов

> Обзор логирования — [Мониторинг и логи](monitoring.md). Просмотр логов — [Grafana](grafana.md) + Loki. Разбор текста в shell — [Обработка текста](text-processing.md).

**Vector** (Datadog, open source, написан на Rust) — конвейер для **логов и метрик**: собирает их из разных источников, разбирает и обогащает, отправляет в одно или несколько хранилищ. Работает как агент на каждом сервере/ноде или как центральный агрегатор.

## Место в стеке

```
 Docker / K8s / файлы / journald / syslog
                │
                ▼
           ┌─────────┐   парсинг, фильтры,
           │ Vector  │   маскирование, лейблы
           └────┬────┘
      ┌─────────┼──────────────┐
      ▼         ▼              ▼
    Loki   Elasticsearch   S3 (архив)      + метрики → Prometheus
```

Сравнение с другими агентами:

| Агент | Особенности |
|---|---|
| **Vector** | быстрый и экономный, мощный язык преобразований VRL, логи + метрики, unit-тесты конфига |
| **Fluent Bit** | очень лёгкий (C), стандарт во многих K8s-дистрибутивах |
| **Fluentd** | много плагинов (Ruby), тяжелее |
| **Logstash** | мощный, но тяжёлый (JVM), обычно как агрегатор в ELK |
| **Promtail** | агент только для Loki; Grafana объявила его устаревшим в пользу **Grafana Alloy** |
| **Filebeat** | агент стека Elastic |

## Модель: sources → transforms → sinks

| Компонент | Что делает | Примеры `type` |
|---|---|---|
| **Source** | откуда брать события | `file`, `docker_logs`, `kubernetes_logs`, `journald`, `syslog`, `http_server`, `vector`, `host_metrics`, `internal_metrics` |
| **Transform** | что с ними сделать | `remap` (VRL), `filter`, `route`, `sample`, `throttle`, `dedupe`, `reduce`, `log_to_metric` |
| **Sink** | куда отправить | `loki`, `elasticsearch`, `aws_s3`, `clickhouse`, `kafka`, `prometheus_exporter`, `vector`, `console` |

Компоненты связываются через `inputs`: у каждого transform и sink — список имён, откуда он получает события. Получается граф.

**Событие (event)** — лог (структура с полями, основное поле — `.message`) или метрика.

## Установка и запуск

```bash
# Docker
docker run -d --name vector \
  -v $(pwd)/vector.yaml:/etc/vector/vector.yaml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  timberio/vector:0.42.0-alpine

# пакет (Debian/Ubuntu) — репозиторий по инструкции на vector.dev
sudo apt install vector
sudo systemctl enable --now vector       # конфиг: /etc/vector/vector.yaml
```

> Номер версии в примерах — ориентир: бери актуальную с [vector.dev](https://vector.dev) и фиксируй её.

## Минимальный конфиг

Прочитать логи nginx и вывести в консоль как JSON — лучший способ начать и посмотреть, какие поля есть у событий:

```yaml
# /etc/vector/vector.yaml
sources:
  nginx:
    type: file
    include:
      - /var/log/nginx/access.log

sinks:
  out:
    type: console
    inputs: [nginx]
    encoding:
      codec: json
```

```bash
vector --config /etc/vector/vector.yaml
# {"file":"/var/log/nginx/access.log","host":"web1","message":"10.0.0.5 - - [27/Sep/2026:10:00:01 +0300] \"GET / HTTP/1.1\" 200 612 ...","source_type":"file","timestamp":"..."}
```

## VRL — язык преобразований

**VRL** (Vector Remap Language) — язык внутри transform `remap`. `.` — текущее событие, `.поле` — поле события.

```yaml
transforms:
  parse:
    type: remap
    inputs: [nginx]
    source: |
      # разобрать строку лога nginx в формате combined
      parsed, err = parse_nginx_log(.message, "combined")
      if err == null {
        . = merge(., parsed)
        del(.message)
      }
      .service = "nginx"
      .env = "${ENV:-dev}"                 # переменная окружения при загрузке конфига
```

Самое нужное:

| Конструкция | Что делает |
|---|---|
| `.field = "value"` | записать поле |
| `del(.field)` | удалить поле |
| `exists(.field)` | есть ли поле |
| `parse_json!(.message)` | разобрать JSON; `!` — при ошибке событие считается ошибочным |
| `x, err = parse_json(.message)` | то же с обработкой ошибки без падения |
| `parse_nginx_log`, `parse_syslog`, `parse_regex`, `parse_key_value`, `parse_timestamp` | готовые парсеры |
| `merge(., obj)` | влить поля объекта в событие |
| `downcase(string!(.level))` | привести к строке и в нижний регистр |
| `to_int!(.status)` | привести тип |
| `redact(.message, filters: [...])` | замаскировать чувствительные данные |
| `abort` | отбросить событие (в `remap` с `drop_on_abort: true`) |

> **Ошибки в VRL проверяются при запуске.** Если функция может упасть (например, `parse_json` на не-JSON), Vector не даст запуститься, пока ты не обработаешь ошибку (`!` или `x, err = ...`). Поэтому конфиг, который стартовал, не падает на странных логах.

Проверять VRL удобно в онлайн-песочнице [playground.vrl.dev](https://playground.vrl.dev) — вставляешь пример события и программу.

## Типовые конфиги

### Docker: логи всех контейнеров → Loki

```yaml
# vector.yaml
data_dir: /var/lib/vector          # где хранить позиции чтения и буферы (нужен том)

api:
  enabled: true                    # для vector top / vector tap
  address: 0.0.0.0:8686

sources:
  docker:
    type: docker_logs
    exclude_containers:
      - vector                     # не читать свои же логи

transforms:
  app_logs:
    type: remap
    inputs: [docker]
    source: |
      # приложения пишут JSON в stdout — разбираем, если получится
      parsed, err = parse_json(.message)
      if err == null && is_object(parsed) {
        . = merge(., object!(parsed))
      }
      .level = downcase(string(.level) ?? "info")
      .service = .label."com.docker.compose.service" || .container_name
      # маскируем номера банковских карт
      .message = redact(string(.message) ?? "", filters: [r'\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b'])

  no_debug:
    type: filter
    inputs: [app_logs]
    condition: '.level != "debug"'

sinks:
  loki:
    type: loki
    inputs: [no_debug]
    endpoint: http://loki:3100
    encoding:
      codec: json
    labels:                        # ТОЛЬКО поля с малым числом значений!
      service: "{{ service }}"
      level: "{{ level }}"
      host: "{{ host }}"
    out_of_order_action: accept
```

> **Лейблы Loki = индекс.** В `labels` — только то, по чему фильтруешь и что имеет мало значений (сервис, окружение, уровень). `user_id`, `request_id`, `trace_id` — в тело лога, иначе Loki (как и Prometheus) захлебнётся кардинальностью.

### Kubernetes: логи подов

```yaml
sources:
  k8s:
    type: kubernetes_logs          # читает /var/log/pods на ноде, добавляет метаданные пода
    extra_label_selector: "logging!=disabled"   # не собирать поды с этой меткой

transforms:
  k8s_parse:
    type: remap
    inputs: [k8s]
    source: |
      parsed, err = parse_json(.message)
      if err == null && is_object(parsed) {
        . = merge(., object!(parsed))
      }
      .namespace = .kubernetes.pod_namespace
      .pod = .kubernetes.pod_name
      .container = .kubernetes.container_name
      .app = .kubernetes.pod_labels."app.kubernetes.io/name" || .kubernetes.pod_labels.app || .container
      del(.kubernetes.pod_annotations)          # лишний объём
      del(.file)

sinks:
  loki:
    type: loki
    inputs: [k8s_parse]
    endpoint: http://loki-gateway.monitoring.svc
    encoding:
      codec: json
    labels:
      namespace: "{{ namespace }}"
      app: "{{ app }}"
      container: "{{ container }}"
```

### journald и syslog

```yaml
sources:
  journal:
    type: journald
    include_units: [nginx, sshd, docker]
    current_boot_only: true

  syslog:
    type: syslog
    address: 0.0.0.0:514
    mode: udp                      # сетевое оборудование шлёт syslog по UDP
```

### Маршрутизация: ошибки отдельно, аудит — в архив

```yaml
transforms:
  split:
    type: route
    inputs: [app_logs]
    route:
      errors: '.level == "error" || .level == "fatal"'
      audit: '.category == "audit"'
    # события, не попавшие ни в один маршрут, доступны как split._unmatched

  sample_info:
    type: sample
    inputs: [split._unmatched]
    rate: 10                       # из обычных логов оставить каждый 10-й

sinks:
  loki_all:
    type: loki
    inputs: [split.errors, sample_info]      # все ошибки + 10% остального
    endpoint: http://loki:3100
    encoding: { codec: json }
    labels:
      service: "{{ service }}"
      level: "{{ level }}"

  audit_archive:
    type: aws_s3
    inputs: [split.audit]
    bucket: company-audit-logs
    region: eu-central-1
    key_prefix: "audit/%Y/%m/%d/"
    compression: gzip
    encoding: { codec: json }
    framing: { method: newline_delimited }
```

### Elasticsearch / OpenSearch

```yaml
sinks:
  es:
    type: elasticsearch
    inputs: [app_logs]
    endpoints: ["https://es.internal:9200"]
    mode: bulk
    bulk:
      index: "logs-{{ service }}-%Y.%m.%d"   # индекс на сервис и день
    auth:
      strategy: basic
      user: vector
      password: "${ES_PASSWORD}"
    tls:
      ca_file: /etc/vector/ca.crt
```

### Метрики из логов → Prometheus

Нет метрик в приложении, но есть логи — посчитаем ошибки по логам:

```yaml
transforms:
  errors_only:
    type: filter
    inputs: [app_logs]
    condition: '.level == "error"'

  error_metrics:
    type: log_to_metric
    inputs: [errors_only]
    metrics:
      - type: counter
        field: level
        name: app_log_errors_total
        tags:
          service: "{{ service }}"

sinks:
  prom:
    type: prometheus_exporter
    inputs: [error_metrics, vector_metrics]
    address: 0.0.0.0:9598          # Prometheus забирает отсюда /metrics

sources:
  vector_metrics:
    type: internal_metrics         # метрики самого Vector: сколько событий, ошибки, буферы
```

Дальше в `prometheus.yml` — job на `vector:9598` (см. [Prometheus](prometheus.md)). Важные метрики самого Vector: `vector_component_errors_total`, `vector_component_discarded_events_total`, `vector_buffer_events`.

## Надёжность доставки: буферы и подтверждения

Хранилище недоступно — что делать с логами?

```yaml
sinks:
  loki:
    type: loki
    # ...
    buffer:
      type: disk                   # буфер на диске переживёт рестарт Vector (по умолчанию memory)
      max_size: 1073741824         # 1 ГБ
      when_full: block             # block — притормозить источник; drop_newest — выкидывать новые
    acknowledgements:
      enabled: true                # источник считает событие доставленным только после ответа sink
    request:
      retry_attempts: 10
```

## Топология: агент и агрегатор

```
ноды (DaemonSet / агент на VM)                 центральный слой
┌──────────────┐
│ Vector agent │──┐                         ┌────────────────────┐     ┌──────┐
└──────────────┘  ├──── sink: vector ──────►│ Vector aggregator  │────►│ Loki │
┌──────────────┐  │                         │ (Deployment, 2+)   │────►│ S3   │
│ Vector agent │──┘                         └────────────────────┘     └──────┘
└──────────────┘
```

* **Агент** — лёгкий: только собрать и отправить (минимум обработки).
* **Агрегатор** — тяжёлые преобразования, маршрутизация, буферы, один набор учётных данных к хранилищам.

```yaml
# на агенте
sinks:
  to_aggregator:
    type: vector
    inputs: [k8s]
    address: vector-aggregator.logging.svc:6000

# на агрегаторе
sources:
  from_agents:
    type: vector
    address: 0.0.0.0:6000
```

## Kubernetes: Helm

```bash
helm repo add vector https://helm.vector.dev
helm upgrade --install vector vector/vector -n logging --create-namespace -f values-vector.yaml
```

```yaml
# values-vector.yaml
role: Agent                        # Agent → DaemonSet на каждой ноде; Aggregator → StatefulSet

customConfig:                      # итоговый vector.yaml целиком
  data_dir: /vector-data-dir
  api:
    enabled: true
    address: 0.0.0.0:8686
  sources:
    k8s:
      type: kubernetes_logs
    vector_metrics:
      type: internal_metrics
  transforms:
    k8s_parse:
      type: remap
      inputs: [k8s]
      source: |
        parsed, err = parse_json(.message)
        if err == null && is_object(parsed) { . = merge(., object!(parsed)) }
        .namespace = .kubernetes.pod_namespace
        .app = .kubernetes.pod_labels.app || .kubernetes.container_name
  sinks:
    loki:
      type: loki
      inputs: [k8s_parse]
      endpoint: http://loki-gateway.monitoring.svc
      encoding: { codec: json }
      labels:
        namespace: "{{ namespace }}"
        app: "{{ app }}"
    prom:
      type: prometheus_exporter
      inputs: [vector_metrics]
      address: 0.0.0.0:9598

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { memory: 512Mi }

podMonitor:
  enabled: true                    # чтобы kube-prometheus-stack собирал метрики Vector
```

## Unit-тесты конфига

Vector умеет проверять transforms без реальных логов — удобно в CI:

```yaml
# в том же vector.yaml или отдельном файле
tests:
  - name: "json-лог разбирается и уровень приводится к нижнему регистру"
    inputs:
      - insert_at: app_logs
        type: log
        log_fields:
          message: '{"level":"ERROR","msg":"payment failed"}'
          container_name: shop
    outputs:
      - extract_from: app_logs
        conditions:
          - type: vrl
            source: |
              assert_eq!(.level, "error")
              assert_eq!(.msg, "payment failed")

  - name: "debug отфильтровывается"
    inputs:
      - insert_at: no_debug
        type: log
        log_fields:
          level: debug
          message: "noise"
    no_outputs_from: [no_debug]
```

## Команды

```bash
vector validate /etc/vector/vector.yaml          # проверить конфиг (и доступность sink-ов)
vector validate --no-environment vector.yaml     # только синтаксис, без проверки подключений (для CI)
vector test /etc/vector/vector.yaml              # прогнать unit-тесты
vector --config /etc/vector/vector.yaml --watch-config   # перезагружать при изменении файла
vector top                                       # живая статистика по компонентам (нужен api)
vector tap app_logs                              # подсмотреть события на выходе компонента
vector tap --outputs-of 'split.*'
vector graph --config vector.yaml | dot -Tsvg > graph.svg   # схема конвейера
vector list                                      # все доступные sources/transforms/sinks
```

`vector tap` — главный инструмент отладки: видно, что реально выходит из каждого шага.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Vector не стартует: `error[E103]: unhandled fallible assignment` | в VRL не обработана возможная ошибка функции | `parse_json!(...)` или `x, err = parse_json(...)` |
| Логов нет в Loki, в Vector ошибок нет | компонент не подключён — опечатка в `inputs` | `vector validate` предупредит; `vector graph`, `vector tap` |
| Loki отвечает `429` / `stream limit exceeded` | слишком много уникальных лейблов | убрать ID из `labels`, оставить сервис/уровень/namespace |
| Loki: `entry out of order` / `too old` | события приходят не по порядку или старые | `out_of_order_action: accept`, настройки `reject_old_samples` в Loki |
| После рестарта логи читаются заново / теряются | нет тома для `data_dir` | постоянный том для `data_dir` |
| Хранилище лежало час — часть логов пропала | буфер в памяти переполнился | `buffer.type: disk`, `when_full: block` |
| В логах пароли и персональные данные | приложение их пишет, Vector пропускает как есть | чинить в приложении + `redact()` в Vector |

## Best Practices

* **Приложения пишут JSON в stdout** — Vector разбирает без хрупких регулярок.
* **Мало лейблов в Loki**, всё остальное — поля в теле лога.
* **Агент лёгкий, обработка — в агрегаторе** (для больших установок).
* **Дисковый буфер и acknowledgements** там, где потеря логов недопустима (аудит).
* **`vector validate` + `vector test` в CI**, конфиг — в git.
* **Мониторь сам Vector**: `internal_metrics` → Prometheus, алерт на ошибки и отброшенные события.
