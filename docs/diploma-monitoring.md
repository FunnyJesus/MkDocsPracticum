# Диплом: мониторинг

Prometheus + Grafana для Momo Store и дашборд по методике **R.E.D.**
Общий обзор — [на главной странице раздела](diploma-momo-store.md),
теория — в разделах [Prometheus](prometheus.md) и [Grafana](grafana.md).

## R.E.D. в двух словах

Для каждого сервиса, который обрабатывает запросы:

| Буква | Что | Вопрос |
|---|---|---|
| **R**ate | запросов в секунду | сколько нагрузки? |
| **E**rrors | доля ошибок (5xx) | сколько из них неудачных? |
| **D**uration | время ответа (p50/p95/p99) | насколько медленно? |

Golden Signals — то же плюс **Saturation** (насколько заняты ресурсы). На дашборде есть и он.

## Откуда метрики

```
backend :8081/metrics ──────── ServiceMonitor ─┐
frontend exporter :9113 ────── ServiceMonitor ─┤
ingress-nginx :10254 ───────── ServiceMonitor ─┼──► Prometheus ──► Grafana
kube-state-metrics, node-exporter, cAdvisor ───┘
```

### Метрики backend (исходный код, не менялся)

| Метрика | Тип | Метки | Для чего |
|---|---|---|---|
| `requests_count` | counter | — | Rate (всего) |
| `response_timing_ms` | histogram, **мс**, бакеты 0..450 шаг 50 | `handler` (путь) | Rate по обработчикам (`_count`), Duration |
| `orders_count` | counter | — | бизнес: заказы |
| `dumplings_listing_count` | counter | `id` | бизнес: просмотры товаров |

!!! warning "В метриках backend нет кода ответа"
    Посчитать **Errors** по метрикам backend нельзя. Поэтому ошибки API берутся из ingress-nginx
    по Ingress `momo-store-api` — через него идут все запросы `/api/*`.

Сначала я переписал метрики backend (`http_requests_total{method,route,status}`), но исходники менять
нельзя — откатил и перестроил дашборд на исходных метриках + ingress.

### Метрики ingress-nginx

| Метрика | Метки |
|---|---|
| `nginx_ingress_controller_requests` | `exported_namespace`, `ingress`, `status`, `method` |
| `nginx_ingress_controller_request_duration_seconds_bucket` | те же + `le` |

!!! note "Почему `exported_namespace`, а не `namespace`"
    Метрика сама содержит метку `namespace` (namespace Ingress'а). При сборе Prometheus добавляет свою
    `namespace` (namespace таргета — `ingress-nginx`). При конфликте исходная переименовывается в
    `exported_namespace`.

!!! danger "Без `metrics-per-host: false` метрик запросов нет вообще"
    ingress-nginx пишет метрики запросов только для хостов из правил Ingress (защита от взрыва
    кардинальности из-за произвольного `Host`). У нас Ingress без `host` (доступ по IP) →
    `nginx_ingress_controller_requests` не появлялась. Таргет при этом `up = 1` — сбивает с толку.

### Метрики nginx фронтенда (exporter)

`nginx_connections_active`, `nginx_http_requests_total` — из `stub_status`; кодов ответа там нет.

## Дашборд «Momo Store — R.E.D.»

Хранится в коде: `infrastructure/helm/momo-store/dashboards/momo-store-red.json`,
генерируется скриптом `generate.py` (так проще поддерживать 22 панели, чем править JSON руками).
Разворачивается вместе с приложением:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: momo-store-dashboard
  labels:
    grafana_dashboard: "1"          # sidecar Grafana ищет ConfigMap с этой меткой во всех namespace
data:
  momo-store-red.json: |-
{{ .Files.Get "dashboards/momo-store-red.json" | indent 4 }}
```

Переменные дашборда: `datasource` (тип datasource, `prometheus`) и `namespace`
(`label_values(kube_namespace_status_phase, namespace)`, по умолчанию `momo-store`).

### Панели и запросы

**Обзор (stat):**

```promql
# Backend: запросов/с
sum(rate(requests_count{namespace="$namespace"}[5m]))

# API: доля 5xx
sum(rate(nginx_ingress_controller_requests{exported_namespace="$namespace",ingress=~".*-api",status=~"5.."}[5m]))
/
sum(rate(nginx_ingress_controller_requests{exported_namespace="$namespace",ingress=~".*-api"}[5m]))
or vector(0)

# Backend: p95 (мс)
histogram_quantile(0.95, sum by (le) (rate(response_timing_ms_bucket{namespace="$namespace"}[5m])))

# Заказов за час
sum(increase(orders_count{namespace="$namespace"}[1h]))
```

**Backend (API) — R.E.D.:**

```promql
# Rate по обработчикам
sum by (handler) (rate(response_timing_ms_count{namespace="$namespace"}[$__rate_interval]))

# Duration p50/p95/p99
histogram_quantile(0.99, sum by (le) (rate(response_timing_ms_bucket{namespace="$namespace"}[$__rate_interval])))

# p95 по обработчикам
histogram_quantile(0.95, sum by (le, handler) (rate(response_timing_ms_bucket{namespace="$namespace"}[$__rate_interval])))

# Ответы API по статусам
sum by (status) (rate(nginx_ingress_controller_requests{exported_namespace="$namespace",ingress=~".*-api"}[$__rate_interval]))
```

**Frontend — R.E.D.:** то же по `ingress=~".*-frontend"` + p95/p99 из
`nginx_ingress_controller_request_duration_seconds_bucket`, активные соединения и RPS из exporter,
топ-5 просматриваемых товаров (`topk(5, sum by (id) (rate(dumplings_listing_count[...])))`).

**Saturation:**

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="$namespace",container!=""}[$__rate_interval]))
sum by (pod) (container_memory_working_set_bytes{namespace="$namespace",container!=""})
kube_deployment_status_replicas_available{namespace="$namespace"}
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="$namespace"}[1h]))
```

!!! tip "Правила, которые стоит помнить"
    * `rate()` — только для counter; сначала `rate`, потом `sum`.
    * `histogram_quantile` — по `_bucket`, обязательно сохранить `le` в `sum by (le, ...)`.
    * `$__rate_interval` вместо фиксированного `[1m]` — Grafana подберёт окно под scrape interval.
    * `container!=""` — убрать агрегированную по поду строку cAdvisor, иначе двойной счёт.
    * `or vector(0)` — показать 0, а не «No data», когда ошибок нет.

## Проверка, что всё собирается

Через API Grafana (прокси к Prometheus), без port-forward:

```bash
P="$(cat ~/.config/yandex-cloud/momo-grafana-password)"
G=http://<ingress_ip>/grafana
DS=$(curl -s -u "admin:$P" "$G/api/datasources" | jq -r '.[] | select(.type=="prometheus") | .uid' | head -1)
q() { curl -s -u "admin:$P" -G "$G/api/datasources/proxy/uid/$DS/api/v1/query" --data-urlencode "query=$1"; }

q 'up{namespace="momo-store"}' | jq -c '[.data.result[].value[1]]'                     # ["1","1","1","1"]
q 'sum by (ingress, status) (nginx_ingress_controller_requests{exported_namespace="momo-store"})' \
  | jq -c '[.data.result[] | "\(.metric.ingress) \(.metric.status)=\(.value[1])"]'
# ["momo-store-api 200=20","momo-store-frontend 200=20"]

# какие вообще метрики есть с префиксом
curl -s -u "admin:$P" "$G/api/datasources/proxy/uid/$DS/api/v1/label/__name__/values" | jq -r '.data[]' | grep ^nginx_ingress

# дашборд загружен?
curl -s -u "admin:$P" "$G/api/search?query=Momo" | jq -r '.[].title'
```

!!! note "zsh и `?` в URL"
    В zsh неэкранированный `?` — glob: `no matches found: http://.../api/search?type=dash-db`.
    URL в кавычки.

Сгенерировать немного трафика для графиков:

```bash
for i in $(seq 1 50); do curl -s -o /dev/null http://<ingress_ip>/api/products; done
```

## Grafana

* Адрес: `http://<ingress_ip>/grafana/`, логин `admin`, пароль — из Secret `grafana-admin`
  (создаёт `install.sh`), локально в `~/.config/yandex-cloud/momo-grafana-password`.
* Работает по подпути: `root_url: "%(protocol)s://%(domain)s/grafana/"` + `serve_from_sub_path: true`.
* Пользователи и сессии — в SQLite внутри пода, **без постоянного диска**: после рестарта пода
  или прерывания узла нужно заново войти. Дашборды не теряются — они из ConfigMap.
* Лимит памяти **512Mi**: с 256Mi Grafana 13 получала `OOMKilled`, и в браузере вылезали
  `ChunkLoadError` и `Error loading: stat` — см. [журнал проблем](diploma-troubleshooting.md).

```bash
# пароль из Secret
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```
