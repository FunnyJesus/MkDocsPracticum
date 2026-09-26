# Трейсинг и OpenTelemetry

> Метрики и логи — [Мониторинг и логи](monitoring.md).

**Observability** стоит на трёх «столпах»:

| Сигнал | Отвечает на вопрос | Инструменты |
|---|---|---|
| **Метрики** | *Что* происходит и сколько? (RPS, ошибки, латентность) | Prometheus, Grafana |
| **Логи** | *Что именно* произошло в конкретном месте? | Loki, ELK |
| **Трейсы** | *Где* в цепочке сервисов теряется время или возникает ошибка? | Jaeger, Tempo, Zipkin |

В монолите хватает логов. В микросервисах один запрос пользователя проходит через 5–15 сервисов, и без трейсинга вопрос «почему оформление заказа занимает 3 секунды» превращается в угадайку.

## Trace и span

**Trace** — путь одного запроса через всю систему. Состоит из **span**-ов — отдельных операций.

```
Trace 4bf92f3577b34da6  (всего 1240 мс)
│
├─ api-gateway   GET /checkout                          ████████████████████ 1240 мс
│  ├─ auth       ValidateToken                          ██ 40 мс
│  ├─ cart       GetCart                                ████ 120 мс
│  │  └─ redis   GET cart:42                             █ 5 мс
│  └─ orders     CreateOrder                            ██████████████ 1050 мс
│     ├─ postgres INSERT orders                          █ 12 мс
│     └─ payments Charge                                ████████████ 1010 мс  ← вот где время
```

| Понятие | Что это |
|---|---|
| **Trace ID** | общий идентификатор всего запроса |
| **Span** | одна операция: имя, начало, длительность, статус |
| **Parent span** | кто вызвал эту операцию — так строится дерево |
| **Attributes** | метаданные span-а: `http.method`, `db.statement`, `user.id` |
| **Events** | события внутри span-а (например, исключение) |
| **Context propagation** | передача trace ID между сервисами — в HTTP-заголовке `traceparent` |

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  └────────── trace-id ───────────┘ └─ parent span ┘ └ флаги (sampled)
             версия
```

Если хотя бы один сервис в цепочке **не передаёт** заголовок — trace рвётся на два несвязанных куска.

## OpenTelemetry (OTel)

**OpenTelemetry** — открытый стандарт (CNCF) для сбора трейсов, метрик и логов. Инструментируешь код один раз, а отправляешь данные в любой бэкенд — Jaeger, Tempo, Datadog, Elastic.

Компоненты:

| Компонент | Что делает |
|---|---|
| **API / SDK** | библиотеки для языков: создание span-ов, метрик |
| **Auto-instrumentation** | span-ы для HTTP, БД, очередей **без правки кода** |
| **OTLP** | протокол передачи данных (gRPC :4317, HTTP :4318) |
| **Collector** | отдельный сервис: принимает, обрабатывает, отправляет дальше |

## Архитектура

```
 сервис A ─┐
 сервис B ─┼─ OTLP ─► OpenTelemetry Collector ─┬─► Tempo / Jaeger   (трейсы)
 сервис C ─┘                                    ├─► Prometheus       (метрики)
                                                └─► Loki             (логи)
                                                          │
                                                       Grafana
```

Почему через Collector, а не напрямую в бэкенд:

* сервисы не знают о бэкенде — сменить Jaeger на Tempo = поменять конфиг Collector;
* батчинг, повторы, фильтрация, удаление чувствительных данных;
* **sampling** в одном месте.

## Инструментирование

### Автоматически (Python)

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install           # поставить инструментации для найденных библиотек

export OTEL_SERVICE_NAME=orders
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1           # 10% трейсов

opentelemetry-instrument python app.py       # Flask/FastAPI/requests/psycopg — span-ы появятся сами
```

Переменные `OTEL_*` одинаковы для всех языков — удобно задавать в Deployment. В Kubernetes **OpenTelemetry Operator** умеет внедрять автоинструментацию аннотацией на под.

### Вручную — свой span

```python
from opentelemetry import trace

tracer = trace.get_tracer(__name__)

def charge(order):
    with tracer.start_as_current_span("charge-card") as span:
        span.set_attribute("order.id", order.id)
        span.set_attribute("payment.amount", order.total)
        ...
```

## Collector: минимальный конфиг

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch: {}
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80

exporters:
  otlp/tempo:
    endpoint: tempo:4317
    tls: { insecure: true }
  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

## Локальный стенд: Jaeger

```bash
docker run -d --name jaeger \
  -p 16686:16686 -p 4317:4317 -p 4318:4318 \
  jaegertracing/jaeger:latest
# UI: http://localhost:16686, приложение шлёт OTLP на localhost:4317
```

## Бэкенды

| Бэкенд | Особенности |
|---|---|
| **Jaeger** | классика CNCF, свой UI |
| **Grafana Tempo** | дешёвое хранение в object storage (S3), смотреть в Grafana |
| **Zipkin** | старейший, простой |
| SaaS | Datadog, Honeycomb, New Relic, Elastic APM |

## Sampling

Хранить 100% трейсов дорого. **Sampling** — сохранять часть:

| Тип | Как | Плюс / минус |
|---|---|---|
| **Head sampling** | решение в начале запроса: «берём 10%» | просто, но можно пропустить редкую ошибку |
| **Tail sampling** | решение после завершения трейса в Collector | можно «все ошибки + все медленные + 5% остальных», но Collector должен держать трейсы в памяти |

## Связка сигналов

Максимум пользы — когда сигналы связаны:

* **trace ID в логах** — из трейса в Grafana один клик до логов этого запроса в Loki;
* **exemplars** — на графике латентности в Prometheus точка ведёт к конкретному медленному трейсу;
* **RED-метрики из span-ов** (Rate, Errors, Duration) — Collector/Tempo считают их автоматически.

```python
# лог с trace_id
logger.info("payment failed", extra={"trace_id": format(span.get_span_context().trace_id, "032x")})
```

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Трейс обрывается на одном из сервисов | сервис не передаёт `traceparent` (нет инструментации HTTP-клиента, прокси режет заголовки) | инструментировать клиент, пропускать заголовки в Nginx/Gateway |
| Трейсов нет вообще | неверный `OTEL_EXPORTER_OTLP_ENDPOINT`, gRPC/HTTP-порт перепутан | 4317 — gRPC, 4318 — HTTP; логи Collector |
| Все сервисы называются `unknown_service` | не задан `OTEL_SERVICE_NAME` | задать в Deployment |
| Счёт за хранение трейсов огромный | 100% sampling | head/tail sampling |
| В трейсах пароли и персональные данные | атрибуты с телом запроса/SQL с параметрами | фильтрация в Collector (`attributes`/`redaction` processor) |

## Best Practices

* **OpenTelemetry вместо проприетарных агентов** — не привязываешься к вендору.
* **Автоинструментация сначала**, ручные span-ы — только в важных местах бизнес-логики.
* **Всегда через Collector.**
* **`service.name` и `deployment.environment`** у каждого сервиса.
* **trace ID в каждой строке лога.**
* **Tail sampling**: все ошибки и медленные запросы + небольшой процент остальных.
