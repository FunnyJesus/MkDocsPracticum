# Grafana: настройка и provisioning

> Обзор мониторинга — [Мониторинг и логи](monitoring.md). Источник метрик — [Prometheus](prometheus.md). Сбор логов — [Vector](vector.md).

**Grafana** — визуализация метрик, логов и трейсов поверх разных источников: Prometheus, Loki, Tempo, Elasticsearch, PostgreSQL и др.

## Основные понятия

* **Data source** — подключение к Prometheus/Loki и т.д.
* **Dashboard** → **Panel** — один график/таблица/gauge на дашборде, обычно с PromQL-запросом внутри.
* **Variables** — переменные в дашборде (например, `$service`), чтобы один дашборд работал для всех сервисов через выпадающий список.
* **Folder** — папки дашбордов, на них вешаются права.
* **Explore** — режим для разовых запросов без создания дашборда (удобно при разборе инцидента).
* **Alerting** — встроенные алерты Grafana (альтернатива правилам Prometheus + Alertmanager).

## Настраивать кодом, а не кликами

Всё, что накликано в UI, живёт только в базе Grafana: пересоздали под — пропало, на другом стенде — по-другому. Поэтому источники данных, дашборды и алерты описывают **файлами provisioning** и хранят в git.

```
grafana/
├── grafana.ini                         # (или переменные окружения GF_*)
├── provisioning/
│   ├── datasources/
│   │   └── datasources.yaml            # Prometheus, Loki, Tempo
│   ├── dashboards/
│   │   └── dashboards.yaml             # откуда брать JSON дашбордов
│   └── alerting/
│       └── contact-points.yaml         # куда слать алерты Grafana
└── dashboards/
    ├── services/
    │   └── shop-red.json
    └── infra/
        └── node-exporter.json
```

Grafana читает `provisioning/` при старте из `/etc/grafana/provisioning` (путь меняется параметром `paths.provisioning`).

## Конфигурация: grafana.ini и переменные окружения

Любую настройку `grafana.ini` можно задать переменной `GF_<СЕКЦИЯ>_<КЛЮЧ>` — удобно в Docker и Kubernetes:

```ini
; grafana.ini
[server]
root_url = https://grafana.example.com

[security]
admin_user = admin
disable_gravatar = true

[users]
allow_sign_up = false

[auth.anonymous]
enabled = false
```

То же через окружение:

```yaml
environment:
  GF_SERVER_ROOT_URL: https://grafana.example.com
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password   # __FILE — прочитать из файла
  GF_USERS_ALLOW_SIGN_UP: "false"
  GF_AUTH_ANONYMOUS_ENABLED: "false"
```

> Суффикс `__FILE` работает для любой переменной `GF_*` — секреты не попадают в `docker inspect` и манифесты.

Вход через корпоративный SSO (GitLab, Keycloak, Google) — секция `[auth.generic_oauth]` / `[auth.gitlab]`: пользователи и роли приходят из SSO, локальные учётки не нужны.

## Provisioning: источники данных

```yaml
# provisioning/datasources/datasources.yaml
apiVersion: 1

# удалить источники, которых больше нет в файле (необязательно)
deleteDatasources:
  - name: Old-Prometheus
    orgId: 1

datasources:
  - name: Prometheus
    uid: prometheus                  # стабильный uid — на него ссылаются дашборды
    type: prometheus
    access: proxy                    # запросы идут через сервер Grafana, а не из браузера
    url: http://prometheus:9090
    isDefault: true
    editable: false                  # запретить правку в UI
    jsonData:
      timeInterval: 15s              # = scrape_interval, для корректного $__rate_interval
      httpMethod: POST

  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      maxLines: 1000
      derivedFields:                 # trace_id в логе → ссылка на трейс в Tempo
        - name: TraceID
          matcherRegex: '"trace_id":"(\w+)"'
          url: "$${__value.raw}"     # $$ — экранирование, иначе Grafana примет за переменную окружения
          datasourceUid: tempo

  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2:                # из трейса → логи этого запроса в Loki
        datasourceUid: loki
        filterByTraceID: true

  - name: Postgres-Analytics
    uid: pg-analytics
    type: grafana-postgresql-datasource
    url: db.internal:5432
    user: grafana_ro
    jsonData:
      database: appdb
      sslmode: require
    secureJsonData:
      password: $PG_GRAFANA_PASSWORD # подставится из переменной окружения
```

В provisioning-файлах работает подстановка переменных окружения: `$VAR` или `${VAR}`. Пароли — только в `secureJsonData` (хранятся зашифрованными).

## Provisioning: дашборды

Сначала **провайдер** — где лежат JSON-файлы:

```yaml
# provisioning/dashboards/dashboards.yaml
apiVersion: 1

providers:
  - name: default
    orgId: 1
    type: file
    folder: ""                         # при foldersFromFilesStructure берётся из папок
    disableDeletion: true              # нельзя удалить из UI
    allowUiUpdates: false              # правки в UI не сохраняются — источник правды git
    updateIntervalSeconds: 30          # перечитывать файлы
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true  # dashboards/services/*.json → папка "services"
```

### JSON дашборда

Дашборд — JSON-документ. Обычно его собирают в UI, затем **Share → Export → Save to file** (с отключённым «Export for sharing externally», чтобы остались uid источников) и кладут в git.

Минимальный пример — RED-дашборд сервиса с переменной `$service`:

```json
{
  "uid": "shop-red",
  "title": "Services — RED",
  "tags": ["services", "red"],
  "timezone": "browser",
  "schemaVersion": 39,
  "refresh": "30s",
  "time": { "from": "now-6h", "to": "now" },
  "templating": {
    "list": [
      {
        "name": "service",
        "label": "Сервис",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": "label_values(http_requests_total, service)",
        "refresh": 2,
        "includeAll": true,
        "multi": true
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Requests per second",
      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (service) (rate(http_requests_total{service=~\"$service\"}[$__rate_interval]))",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] }
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Error rate (5xx)",
      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "sum by (service) (rate(http_requests_total{service=~\"$service\", status=~\"5..\"}[$__rate_interval])) / sum by (service) (rate(http_requests_total{service=~\"$service\"}[$__rate_interval]))",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "red", "value": 0.05 }
            ]
          }
        },
        "overrides": []
      }
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "Latency p95",
      "gridPos": { "x": 0, "y": 8, "w": 24, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [
        {
          "refId": "A",
          "expr": "histogram_quantile(0.95, sum by (service, le) (rate(http_request_duration_seconds_bucket{service=~\"$service\"}[$__rate_interval])))",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] }
    }
  ]
}
```

| Поле | Зачем |
|---|---|
| `uid` | постоянный идентификатор — URL дашборда `/d/shop-red`, ссылки из алертов |
| `templating.list` | переменные; `label_values(метрика, лейбл)` — значения для выпадающего списка |
| `gridPos` | положение панели: сетка шириной 24 колонки |
| `$__rate_interval` | правильное окно для `rate()` с учётом `scrape_interval` — используй вместо `[5m]` |
| `legendFormat` | подпись линии: `{{service}}` — значение лейбла |
| `unit` | `reqps`, `percentunit` (0–1 → %), `s`, `bytes`, `short` |

> Готовые дашборды — на [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards/): например **Node Exporter Full (ID 1860)**. Импорт: Dashboards → New → Import → ID. Для provisioning — скачать JSON и положить в папку.

### Типы переменных

| Тип | Пример | Для чего |
|---|---|---|
| `query` | `label_values(up, job)` | значения из источника |
| `custom` | `prod,staging,dev` | фиксированный список |
| `interval` | `1m,5m,1h` | выбор окна агрегации |
| `datasource` | тип `prometheus` | переключать кластер/Prometheus на одном дашборде |
| `constant` / `textbox` | — | скрытое значение / ввод текста |

## Provisioning: алерты Grafana

Выбери **один** механизм алертинга на команду, чтобы не дублировать:

* **Prometheus rules + Alertmanager** ([Prometheus](prometheus.md)) — правила рядом с метриками, стандарт в Kubernetes;
* **Grafana Alerting** — удобно, если алерты нужны и по Loki/SQL/другим источникам в одном месте.

Contact point и политика уведомлений:

```yaml
# provisioning/alerting/contact-points.yaml
apiVersion: 1

contactPoints:
  - orgId: 1
    name: oncall-telegram
    receivers:
      - uid: oncall-telegram
        type: telegram
        settings:
          bottoken: $TELEGRAM_BOT_TOKEN
          chatid: "-1001234567890"
        disableResolveMessage: false

policies:
  - orgId: 1
    receiver: oncall-telegram
    group_by: [grafana_folder, alertname]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
```

Сами правила тоже можно провиженить (`groups:` в `provisioning/alerting/*.yaml`). Проще всего: создать правило в UI → **More → Export** → положить YAML в git.

## Docker Compose

```yaml
services:
  grafana:
    image: grafana/grafana:11.3.0
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password
      GF_USERS_ALLOW_SIGN_UP: "false"
    secrets:
      - grafana_admin_password
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana          # пользователи, настройки, аннотации

secrets:
  grafana_admin_password:
    file: ./secrets/grafana_admin_password.txt

volumes:
  grafana-data:
```

## Kubernetes: sidecar для дашбордов

В kube-prometheus-stack (и в чарте `grafana/grafana`) дашборды и источники подхватывает **sidecar**: он следит за ConfigMap-ами с нужной меткой и сам кладёт их в Grafana.

```yaml
# values-monitoring.yaml (фрагмент kube-prometheus-stack)
grafana:
  admin:
    existingSecret: grafana-admin      # Secret с ключами admin-user / admin-password
    userKey: admin-user
    passwordKey: admin-password
  grafana.ini:
    server:
      root_url: https://grafana.example.com
    users:
      allow_sign_up: false
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard         # искать ConfigMap-ы с этой меткой
      labelValue: "1"
      searchNamespace: ALL             # во всех namespace
      folderAnnotation: grafana_folder # папка — из аннотации ConfigMap
      provider:
        foldersFromFilesStructure: true
    datasources:
      enabled: true
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      url: http://loki-gateway.monitoring.svc
```

Дашборд команды приложения — ConfigMap рядом с её манифестами:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-dashboard
  namespace: shop
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: Services
data:
  shop-red.json: |
    { "uid": "shop-red", "title": "Shop — RED", "panels": [ ... ] }
```

С Kustomize удобно генерировать такой ConfigMap из файла: `configMapGenerator` с `files: [shop-red.json]` и `options.labels` (см. [Kustomize](kustomize.md)).

## Grafana как код: другие способы

| Инструмент | Что делает |
|---|---|
| **Terraform provider `grafana`** | папки, дашборды, источники, алерты, права — ресурсами Terraform |
| **Grafonnet** (Jsonnet) | дашборды кодом с переиспользованием: одна функция → десятки одинаковых панелей |
| **Grafana Operator** | CRD `GrafanaDashboard`, `GrafanaDatasource` в Kubernetes |
| **HTTP API** | `POST /api/dashboards/db` — загрузка из CI |

```bash
# полезные вызовы API
curl -s http://localhost:3000/api/health
curl -s -u admin:$PASS http://localhost:3000/api/search?query=shop | jq
curl -s -u admin:$PASS http://localhost:3000/api/dashboards/uid/shop-red | jq '.dashboard' > shop-red.json
```

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| На панели `No data` | неверный uid источника в JSON, запрос не находит метрику, переменная пустая | Explore с тем же запросом; проверить `datasource.uid` |
| Импортированный дашборд «не видит» источник | JSON экспортирован с `${DS_PROMETHEUS}` (for sharing externally) | заменить на uid своего источника или экспортировать без этой опции |
| Правки дашборда пропадают после рестарта | провижененный дашборд с `allowUiUpdates: false` или нет тома | править JSON в git; том для `/var/lib/grafana` |
| График `rate()` рваный или пустой при большом масштабе | окно `[1m]` меньше двух scrape-интервалов | `$__rate_interval` + `timeInterval` в источнике |
| Ссылка из Loki в Tempo не работает | `$` в `url` не экранирован в provisioning | `$${__value.raw}` |
| Пароль admin в манифесте в открытом виде | `adminPassword` в values | `admin.existingSecret` / `__FILE` |

## Best Practices

* **Всё через provisioning и git**: источники, дашборды, алерты. UI — для черновиков.
* **Стабильные `uid`** у источников и дашбордов.
* **Один дашборд на тип сервиса с переменными**, а не копия на каждый сервис.
* **Сверху — симптомы** (RED, SLO), ниже — детали (ресурсы, зависимости).
* **Связывай сигналы**: метрики → логи (Loki) → трейсы (Tempo) в один клик.
* **SSO и роли вместо общих учёток**, анонимный доступ выключен.
