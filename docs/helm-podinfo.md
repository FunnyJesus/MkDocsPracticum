# Helm: production-ready чарт (podinfo)

Разбор того, как превратить набор разрозненных YAML-манифестов в **эталонный Helm-чарт**: параметризуемый, с условными ресурсами, встроенным Redis, dev/prod-конфигурациями, хуками и тестами. Основа — сервис [podinfo](https://github.com/stefanprodan/podinfo), который платформенные команды часто используют как «подопытный» микросервис.

> Базовая теория Helm (чарт, values, релиз, ревизии, `install`/`upgrade`/`rollback`) — [Helm (теория)](helm.md). Здесь — то, что нужно сверх неё для продакшн-чарта.

`эталонный чарт` — чарт, который копируют как основу для других сервисов. Поэтому в нём важна не только работоспособность, но и **единообразие**: одинаковые имена, метки, структура values, одинаковое поведение `enabled`-флагов.

`values.yaml как интерфейс` — values читаются как API чарта: пользователь меняет поведение, не открывая шаблоны. Всё, что может понадобиться поменять, вынесено в values; всё, что меняться не должно, — не вынесено.

## Что такое podinfo

Небольшой Go-сервис, который умеет всё, что нужно для проверки кластера: отдаёт health-эндпоинты, метрики, умеет кешировать в Redis, специально отвечать ошибкой или «зависать».

| Порт | Назначение |
|---|---|
| `9898` | HTTP API (основной) |
| `9797` | Prometheus-метрики (`/metrics`) |
| `9999` | gRPC |

| Эндпоинт | Что делает | Зачем в чарте |
|---|---|---|
| `GET /healthz` | liveness | `livenessProbe` |
| `GET /readyz` | readiness | `readinessProbe` |
| `GET /version` | версия приложения | HTTP-тест |
| `POST/GET/DELETE /cache/{key}` | записать / прочитать / удалить ключ в Redis | cache-тест |
| `GET /status/{code}` | ответить заданным HTTP-кодом | негативный тест |
| `GET /delay/{seconds}` | ответить через N секунд | сценарий «медленный бэкенд» |

Параметры запуска — флаги командной строки: `--port`, `--port-metrics`, `--grpc-port`, `--level`, `--ui-message`, `--ui-color`, `--cache-server=tcp://host:6379`.

## Архитектура чарта

```
podinfo/
├── Chart.yaml
├── values.yaml              # dev-умолчания + документированный интерфейс
├── values-prod.yaml         # только отличия prod
├── .helmignore
└── templates/
    ├── _helpers.tpl         # имена, метки, адрес Redis, образ
    ├── NOTES.txt
    ├── deployment.yaml
    ├── service.yaml         # if service.enabled
    ├── ingress.yaml         # if ingress.enabled
    ├── hpa.yaml             # if hpa.enabled
    ├── pdb.yaml             # if pdb.enabled
    ├── serviceaccount.yaml  # if serviceAccount.create
    ├── hooks.yaml           # if hooks.enabled — Job на каждое событие
    ├── redis/               # внутренний компонент, if redis.enabled
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   └── service.yaml
    └── tests/               # helm test
        ├── _pod.tpl         # общий каркас тестового пода
        ├── test-http.yaml
        ├── test-cache.yaml  # if redis.enabled
        ├── test-fail.yaml   # if tests.fail.enabled
        └── test-timeout.yaml# if tests.timeout.enabled
```

Как ресурсы связаны между собой:

```
             Ingress (<fullname>)
                  │ backend
                  ▼
             Service (<fullname>) ──selector: name+instance+component=app──┐
                                                                            ▼
HPA (<fullname>) ──scaleTargetRef──▶ Deployment (<fullname>) ──▶ pods podinfo
PDB (<fullname>) ──selector: component=app─────────────────────────────────┘
                                                 │ --cache-server=tcp://<fullname>-redis:6379
                                                 ▼
             Service (<fullname>-redis) ──selector: component=redis──▶ pod redis
             ConfigMap (<fullname>-redis) ──checksum──▶ Deployment (<fullname>-redis, Recreate)
```

> Файлы, начинающиеся с `_` (`_helpers.tpl`, `tests/_pod.tpl`), Helm **не рендерит как манифесты** — в них живут только `define`-блоки. Поэтому общий каркас тестов можно положить прямо в `templates/tests/`.

## Chart.yaml

```yaml
apiVersion: v2
name: podinfo
description: podinfo — эталонный микросервис платформы
type: application
version: 0.1.0          # версия чарта — поднимать при каждой правке шаблонов
appVersion: "6.7.1"     # версия podinfo = тег образа по умолчанию
```

> Redis здесь **не** описан в `dependencies` — по заданию он часть архитектуры самого чарта. Разница: dependency — чужой чарт со своими values и своей логикой имён; внутренний компонент — ваши шаблоны, ваши метки, ваше имя `<fullname>-redis`, полный контроль над тем, что создаётся.

## values.yaml как интерфейс

Принципы, по которым values читается как конфигурация, а не как «сборник переменных»:

* **Группировка по компонентам**: `image`, `service`, `ingress`, `hpa`, `pdb`, `redis`, `hooks`, `tests` — каждый блок самодостаточен.
* **Каждый опциональный ресурс — `<блок>.enabled`**. Одинаковое имя флага везде, без `createIngress`/`useHpa`/`withRedis`.
* **Умолчания = dev**: минимально, дёшево, без внешних зависимостей. Prod включает нужное через override-файл.
* **Порт задаётся в одном месте** и используется и в контейнере, и в пробах, и в Service.
* **Комментарии к неочевидным полям** — что будет, если оставить пустым.
* **Пустое значение = «не добавлять»** (`resources: {}`, `imagePullSecrets: []`, `grpcPort: 0`) — шаблон проверяет через `with`/`if` и просто не выводит блок.

```yaml
# ---------- общее ----------
nameOverride: ""
fullnameOverride: ""

# ---------- приложение ----------
replicaCount: 1            # игнорируется, если hpa.enabled=true

image:
  repository: ghcr.io/stefanprodan/podinfo
  tag: ""                  # пусто → appVersion из Chart.yaml
  pullPolicy: IfNotPresent

imagePullSecrets: []       # [{ name: regcred }]

serviceAccount:
  create: false
  name: ""                 # пусто → <fullname>
  annotations: {}

# параметры запуска podinfo
podinfo:
  logLevel: info
  uiMessage: ""
  uiColor: "#34577c"
  extraArgs: []            # ["--random-delay=true"]

# порты контейнера (одно место правды для Deployment, Service, проб)
ports:
  http: 9898
  metrics: 9797
  grpc: 9999

resources: {}

strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1

podAnnotations: {}
nodeSelector: {}
tolerations: []
affinity: {}

# ---------- Service ----------
service:
  enabled: true
  type: ClusterIP
  httpPort: 9898
  metricsPort: 9797        # 0/пусто → порт не добавляется
  grpcPort: 0
  nodePort: ""             # используется только при type: NodePort

# ---------- Ingress ----------
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: podinfo.local
      paths:
        - path: /
          pathType: Prefix
  tls: []
  #  - secretName: podinfo-tls
  #    hosts: [podinfo.local]

# ---------- HPA ----------
hpa:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  cpuUtilization: 70       # пусто → метрика не добавляется
  memoryUtilization: ""

# ---------- PDB ----------
pdb:
  enabled: false
  minAvailable: 1          # задайте ЛИБО minAvailable, ЛИБО maxUnavailable
  maxUnavailable: ""

# ---------- Redis (внутренний компонент) ----------
redis:
  enabled: false
  image:
    repository: redis
    tag: "7.2-alpine"
    pullPolicy: IfNotPresent
  port: 6379
  config: |
    maxmemory 64mb
    maxmemory-policy allkeys-lru
    save ""
    appendonly no
  resources: {}

# ---------- хуки ----------
hooks:
  enabled: false
  image: busybox:1.36
  events:
    - pre-install
    - post-install
    - pre-upgrade
    - post-upgrade
    - pre-delete
    - post-delete
    - pre-rollback
    - post-rollback
  deletePolicy: before-hook-creation,hook-succeeded

# ---------- тесты (helm test) ----------
tests:
  image: curlimages/curl:8.10.1
  http:
    enabled: true
  cache:
    enabled: true          # фактически только при redis.enabled=true
  fail:
    enabled: false         # негативный сценарий: тест обязан упасть
  timeout:
    enabled: false         # тест зависает дольше, чем helm test --timeout
    sleepSeconds: 600
```

> Проверка «values как интерфейс»: можно ли поменять образ, порт, число реплик, включить Redis — **не открывая `templates/`**? Если для какой-то настройки приходится править шаблон — это захардкоженное значение.

## _helpers.tpl: имена и метки

Именованные шаблоны (`define`) — единственное место, где формируются имена и метки. Все манифесты вызывают их через `include`, поэтому переименование или новая метка меняется в одной точке.

```yaml
{{/* Короткое имя чарта */}}
{{- define "podinfo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Полное имя: <release>-<chart>, не длиннее 63 символов (лимит DNS) */}}
{{- define "podinfo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "podinfo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Метки, общие для ВСЕХ ресурсов (в selector НЕ попадают) */}}
{{- define "podinfo.commonLabels" -}}
helm.sh/chart: {{ include "podinfo.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "podinfo.name" . }}
{{- end }}

{{/* База селектора: приложение + релиз */}}
{{- define "podinfo.baseSelectorLabels" -}}
app.kubernetes.io/name: {{ include "podinfo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ---------- podinfo ---------- */}}
{{- define "podinfo.selectorLabels" -}}
{{ include "podinfo.baseSelectorLabels" . }}
app.kubernetes.io/component: app
{{- end }}

{{- define "podinfo.labels" -}}
{{ include "podinfo.commonLabels" . }}
{{ include "podinfo.selectorLabels" . }}
{{- end }}

{{/* ---------- redis ---------- */}}
{{- define "podinfo.redis.fullname" -}}
{{- printf "%s-redis" (include "podinfo.fullname" . | trunc 57 | trimSuffix "-") }}
{{- end }}

{{- define "podinfo.redis.selectorLabels" -}}
{{ include "podinfo.baseSelectorLabels" . }}
app.kubernetes.io/component: redis
{{- end }}

{{- define "podinfo.redis.labels" -}}
{{ include "podinfo.commonLabels" . }}
{{ include "podinfo.redis.selectorLabels" . }}
{{- end }}

{{/* Адрес кеша для podinfo: tcp://<fullname>-redis:<port> */}}
{{- define "podinfo.redis.url" -}}
{{- printf "tcp://%s:%v" (include "podinfo.redis.fullname" .) .Values.redis.port }}
{{- end }}

{{/* ---------- ServiceAccount ---------- */}}
{{- define "podinfo.serviceAccountName" -}}
{{- default (include "podinfo.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{/* Образ: repository:tag, tag по умолчанию = appVersion */}}
{{- define "podinfo.image" -}}
{{- printf "%s:%s" (required "image.repository обязателен" .Values.image.repository) (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
```

### Почему имена устроены именно так

| Приём | Зачем |
|---|---|
| `trunc 63 \| trimSuffix "-"` | имя ресурса и DNS-метка в K8s — максимум 63 символа; после обрезки не должен остаться `-` на конце |
| `contains $name .Release.Name` | релиз `podinfo` даст `podinfo`, а не `podinfo-podinfo` |
| `nameOverride` / `fullnameOverride` | можно поставить два релиза чарта рядом или подстроиться под чужие имена без правки шаблонов |
| `trunc 57` в `redis.fullname` | 57 + `-redis` (6 символов) = 63 — суффикс не отрежется |

### Метки: labels ≠ selector

Стандартные [рекомендованные метки Kubernetes](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/) делятся на две группы:

| Группа | Метки | Где используются |
|---|---|---|
| **selector** (стабильные) | `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/component` | `spec.selector` Deployment/Service/PDB, метки пода |
| **common** (меняются) | `helm.sh/chart`, `app.kubernetes.io/version`, `app.kubernetes.io/managed-by`, `app.kubernetes.io/part-of` | только `metadata.labels` |

* **Версию нельзя класть в selector.** `spec.selector` у Deployment неизменяем: при следующем `helm upgrade` с новой версией чарта получите `field is immutable`.
* **`component` в selector обязателен, когда в чарте несколько подов.** Без него `name+instance` у podinfo и Redis совпадают — и Service podinfo начнёт балансировать трафик на под Redis (и наоборот). Отдельный `component: app` / `component: redis` разводит их.
* **Хуки и тесты получают только common-метки + свой `component` (`hook`/`test`)**, но не selector-метки приложения — иначе тестовый под попал бы в Endpoints сервиса.

### Техники шаблонизации, которые используются дальше

| Конструкция | Что делает | Пример применения |
|---|---|---|
| `include "x" . \| nindent N` | вставить именованный шаблон с отступом | метки, selector |
| `with .Values.x` | блок выводится, только если значение непустое; внутри `.` = это значение | `imagePullSecrets`, `resources`, `annotations` |
| `if` / `if not` / `and` / `or` | условный вывод | `replicas`, `--cache-server`, ресурсы по `enabled` |
| `range` | цикл по списку | хосты Ingress, события хуков, `extraArgs` |
| `$` | корневой контекст внутри `range`/`with`, где `.` переопределён | `include "podinfo.fullname" $` в хуках |
| `toYaml . \| nindent N` | вставить структуру из values как YAML-блок | `strategy`, `tls`, `resources` |
| `required "msg" .Values.x` | упасть при рендере, если значения нет | `image.repository` |
| `fail "msg"` | упасть при рендере с объяснением | несовместимые настройки |
| `default` | значение по умолчанию | тег образа = `appVersion` |
| `quote` | в кавычки | версии, строки с пробелами |

> `nindent` вместо `indent`: `nindent` сначала ставит перевод строки, поэтому шаблон пишется как `labels:` + `{{- include ... | nindent 4 }}` и отступ всегда правильный. `{{-` съедает пустую строку перед вставкой.

## Deployment приложения

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "podinfo.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.labels" . | nindent 4 }}
spec:
  {{- if not .Values.hpa.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  strategy:
    {{- toYaml .Values.strategy | nindent 4 }}
  selector:
    matchLabels:
      {{- include "podinfo.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "podinfo.selectorLabels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- if .Values.serviceAccount.create }}
      serviceAccountName: {{ include "podinfo.serviceAccountName" . }}
      {{- end }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: {{ include "podinfo.image" . | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command:
            - ./podinfo
            - --port={{ .Values.ports.http }}
            - --port-metrics={{ .Values.ports.metrics }}
            - --grpc-port={{ .Values.ports.grpc }}
            - --level={{ .Values.podinfo.logLevel }}
            {{- with .Values.podinfo.uiMessage }}
            - --ui-message={{ . }}
            {{- end }}
            - --ui-color={{ .Values.podinfo.uiColor }}
            {{- if .Values.redis.enabled }}
            - --cache-server={{ include "podinfo.redis.url" . }}
            {{- end }}
            {{- range .Values.podinfo.extraArgs }}
            - {{ . | quote }}
            {{- end }}
          ports:
            - name: http
              containerPort: {{ .Values.ports.http }}
              protocol: TCP
            - name: http-metrics
              containerPort: {{ .Values.ports.metrics }}
              protocol: TCP
            - name: grpc
              containerPort: {{ .Values.ports.grpc }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

Разбор требований:

| Требование | Как решено |
|---|---|
| `replicaCount` | `replicas` выводится только при `hpa.enabled=false` |
| ServiceAccount | `serviceAccountName` только при `serviceAccount.create=true`, иначе под получает `default` |
| `imagePullSecrets` | `with` — блок появляется, только если список непустой |
| Параметры запуска через values | флаги собираются из `podinfo.*`, `ports.*`; всё нестандартное — через `extraArgs` |
| `--cache-server` | добавляется только при `redis.enabled=true`, адрес — из хелпера `podinfo.redis.url` |
| Нет простоя при обновлении | `maxUnavailable: 0` + `readinessProbe`: старый под убирается только после того, как новый стал Ready |

> Пробы указывают на **именованный** порт `http`, а не на число — поменяли `ports.http` в values, и пробы, контейнер, Service поменялись вместе.

## Service

```yaml
{{- if .Values.service.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "podinfo.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "podinfo.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.httpPort }}
      targetPort: http
      protocol: TCP
      {{- if and (eq .Values.service.type "NodePort") .Values.service.nodePort }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
    {{- if .Values.service.metricsPort }}
    - name: http-metrics
      port: {{ .Values.service.metricsPort }}
      targetPort: http-metrics
      protocol: TCP
    {{- end }}
    {{- if .Values.service.grpcPort }}
    - name: grpc
      port: {{ .Values.service.grpcPort }}
      targetPort: grpc
      protocol: TCP
    {{- end }}
{{- end }}
```

* **Selector берётся из того же хелпера**, что и `matchLabels` Deployment — рассинхрон невозможен физически.
* **`targetPort` — по имени порта контейнера**, а не числом.
* **`nodePort`** выводится, только если `type: NodePort` **и** порт задан; при `ClusterIP` поле `nodePort` вызвало бы ошибку API.

## Ingress

```yaml
{{- if .Values.ingress.enabled }}
{{- if not .Values.service.enabled }}
{{- fail "ingress.enabled=true требует service.enabled=true" }}
{{- end }}
{{- $fullname := include "podinfo.fullname" . }}
{{- $port := .Values.service.httpPort }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullname }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .Values.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with .Values.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ $fullname }}
                port:
                  number: {{ $port }}
          {{- end }}
    {{- end }}
{{- end }}
```

> Внутри `range` точка `.` — это текущий элемент списка (хост, потом путь), поэтому `.Values...` там недоступен. Нужные значения заранее кладут в переменные (`$fullname`, `$port`) или обращаются через `$.Values`.

* `ingressClassName` — вместо устаревшей аннотации `kubernetes.io/ingress.class`. Пустое значение → поле не выводится → используется IngressClass по умолчанию.
* `fail` при выключенном Service: Ingress без backend-сервиса — ошибка конфигурации, её лучше поймать на `helm template`, чем в кластере.
* TLS-сертификат (Secret `podinfo-prod-tls`) чарт не создаёт — его выпускает cert-manager или кладут заранее.

## HPA

```yaml
{{- if .Values.hpa.enabled }}
{{- if not (or .Values.hpa.cpuUtilization .Values.hpa.memoryUtilization) }}
{{- fail "hpa.enabled=true: задайте hpa.cpuUtilization и/или hpa.memoryUtilization" }}
{{- end }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "podinfo.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "podinfo.fullname" . }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    {{- with .Values.hpa.cpuUtilization }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
    {{- with .Values.hpa.memoryUtilization }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
{{- end }}
```

### Почему `replicas` и HPA конфликтуют

HPA сам меняет `spec.replicas` у Deployment. Если в манифесте чарта тоже есть `replicas: 3`, то при **каждом** `helm upgrade` Helm (трёхстороннее слияние: старый манифест, новый манифест, живое состояние) вернёт `replicas` к 3 — HPA раскрутил до 8 под нагрузкой, деплой сбросил до 3, HPA снова поднимает. Отсюда правило:

> **При `hpa.enabled=true` поле `replicas` в Deployment не выводится вообще** — число реплик принадлежит HPA, диапазон задаётся `minReplicas`/`maxReplicas`.

Нюанс: если включить HPA **upgrade'ом** на релизе, где `replicas` раньше было, Helm удалит поле из Deployment, и оно на мгновение вернётся к значению по умолчанию (1), пока HPA не поднимет до `minReplicas`. Для prod безопаснее ставить сразу с включённым HPA.

### Чтобы HPA реально работал

* **metrics-server** в кластере (в minikube: `minikube addons enable metrics-server`). Без него в `kubectl get hpa` будет `<unknown>/70%`.
* **`resources.requests`** у контейнера. `averageUtilization` считается в процентах **от requests** — без requests HPA не знает, от чего считать проценты. Поэтому `resources` заданы в `values-prod.yaml`.

```bash
kubectl get hpa -n <ns>
# NAME      REFERENCE            TARGETS                        MINPODS  MAXPODS  REPLICAS
# podinfo   Deployment/podinfo   cpu: 2%/70%, memory: 15%/80%   3        10       3
```

## PDB

```yaml
{{- if .Values.pdb.enabled }}
{{- $min := .Values.pdb.minAvailable }}
{{- $max := .Values.pdb.maxUnavailable }}
{{- $hasMin := not (or (kindIs "invalid" $min) (eq (toString $min) "")) }}
{{- $hasMax := not (or (kindIs "invalid" $max) (eq (toString $max) "")) }}
{{- if eq $hasMin $hasMax }}
{{- fail "pdb: задайте ровно одно из pdb.minAvailable / pdb.maxUnavailable" }}
{{- end }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "podinfo.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.labels" . | nindent 4 }}
spec:
  {{- if $hasMin }}
  minAvailable: {{ $min }}
  {{- else }}
  maxUnavailable: {{ $max }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "podinfo.selectorLabels" . | nindent 6 }}
{{- end }}
```

* **Ровно одно поле.** Kubernetes не принимает PDB с `minAvailable` и `maxUnavailable` одновременно — `fail` ловит это на рендере.
* **Ловушка с нулём:** в Go-шаблонах `0` — «ложь», поэтому `{{ if .Values.pdb.minAvailable }}` при `minAvailable: 0` молча выбросит поле. Проверка через `kindIs "invalid"` (значение `null`/не задано) и сравнение с `""` отличает «не задано» от «задано нулём».
* **Переключение на `maxUnavailable`** в override-файле: `minAvailable: null` + `maxUnavailable: 1` (`null` удаляет ключ из умолчаний).
* PDB защищает от **добровольных** эвакуаций (`kubectl drain`, обновление нод), но **не** влияет на rolling update — за него отвечает `strategy`.
* `minAvailable: 1` при одной реплике = нода никогда не осушится. PDB имеет смысл при ≥2 репликах, поэтому в prod он включён вместе с HPA `minReplicas: 3`.

## Redis как внутренний компонент

Три ресурса, все под одним флагом `redis.enabled`, все с именем `<fullname>-redis` и меткой `component: redis`.

### templates/redis/configmap.yaml

```yaml
{{- if .Values.redis.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "podinfo.redis.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.redis.labels" . | nindent 4 }}
data:
  redis.conf: |
    port {{ .Values.redis.port }}
    {{- .Values.redis.config | nindent 4 }}
{{- end }}
```

### templates/redis/deployment.yaml

```yaml
{{- if .Values.redis.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "podinfo.redis.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.redis.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "podinfo.redis.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "podinfo.redis.selectorLabels" . | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/redis/configmap.yaml") . | sha256sum }}
    spec:
      containers:
        - name: redis
          image: "{{ .Values.redis.image.repository }}:{{ .Values.redis.image.tag }}"
          imagePullPolicy: {{ .Values.redis.image.pullPolicy }}
          command: ["redis-server", "/etc/redis/redis.conf"]
          ports:
            - name: redis
              containerPort: {{ .Values.redis.port }}
              protocol: TCP
          livenessProbe:
            tcpSocket:
              port: redis
          readinessProbe:
            exec:
              command: ["redis-cli", "-p", "{{ .Values.redis.port }}", "ping"]
          {{- with .Values.redis.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: config
              mountPath: /etc/redis
      volumes:
        - name: config
          configMap:
            name: {{ include "podinfo.redis.fullname" . }}
{{- end }}
```

### templates/redis/service.yaml

```yaml
{{- if .Values.redis.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "podinfo.redis.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "podinfo.redis.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "podinfo.redis.selectorLabels" . | nindent 4 }}
  ports:
    - name: redis
      port: {{ .Values.redis.port }}
      targetPort: redis
      protocol: TCP
{{- end }}
```

### Ключевые решения

| Решение | Зачем |
|---|---|
| `strategy: Recreate` | Redis — одиночный stateful-процесс. При `RollingUpdate` на время обновления живут **два** Redis, и клиенты пишут в разные экземпляры; с томом `ReadWriteOnce` новый под вообще не стартует, пока старый держит том. `Recreate` сначала гасит старый под, потом поднимает новый |
| `checksum/config` | Kubernetes **не** перезапускает поды при изменении ConfigMap. Хеш содержимого ConfigMap в аннотации пода: конфиг поменялся → хеш поменялся → изменился pod template → Deployment пересоздаёт под |
| `include (print $.Template.BasePath "/redis/configmap.yaml")` | рендерит соседний шаблон как строку — хешируется ровно то, что уйдёт в кластер |
| Имя `<fullname>-redis` из хелпера | один источник правды для Service Redis и для флага `--cache-server` у podinfo |
| `component: redis` в selector | Service Redis не выбирает поды podinfo, Service podinfo не выбирает под Redis |

**DNS.** Service `<fullname>-redis` в namespace релиза получает имя `<fullname>-redis.<namespace>.svc.cluster.local`. Поды podinfo в том же namespace резолвят его по короткому имени, поэтому `--cache-server=tcp://<fullname>-redis:6379` достаточно.

```bash
# DNS работает
kubectl run dns-check -n <ns> --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup podinfo-redis

# Redis отвечает
kubectl exec -n <ns> deploy/podinfo-redis -- redis-cli ping      # PONG

# podinfo реально пишет в Redis: он периодически кладёт ключ <имя пода> = <версия>
kubectl exec -n <ns> deploy/podinfo-redis -- redis-cli keys '*'

# логи podinfo: если Redis недоступен, podinfo пишет предупреждение "cache server is offline"
kubectl logs -n <ns> deploy/podinfo | grep -i cache
```

> Самое надёжное подтверждение подключения — cache-тест (`helm test`, см. ниже): записать ключ через API podinfo и прочитать его обратно.

## values-prod.yaml

Только отличия от `values.yaml`:

```yaml
replicaCount: 3            # используется, если HPA выключат

podinfo:
  logLevel: warn
  uiMessage: "production"

resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi

hpa:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  cpuUtilization: 70
  memoryUtilization: 80

pdb:
  enabled: true
  minAvailable: 2

redis:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: podinfo.prod.local
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: podinfo-prod-tls
      hosts:
        - podinfo.prod.local
```

| Параметр | dev (`values.yaml`) | prod (`-f values-prod.yaml`) |
|---|---|---|
| Реплики | `replicaCount: 1` | HPA 3–10 |
| HPA | выключен | CPU 70 % + memory 80 % |
| Ресурсы | не заданы | requests + limits |
| Redis | выключен | включён |
| Ingress | выключен | включён, `nginx`, TLS |
| PDB | выключен | `minAvailable: 2` |
| Логи | `info` | `warn` |

> Словари (`resources`, `redis`) при `-f` **сливаются** с умолчаниями по ключам, а списки (`hosts`, `tls`) **заменяются целиком**. Поэтому в prod `ingress.hosts` описан полностью, а в `redis` достаточно написать только `enabled` и `resources`.

```bash
# prod-релиз — только через override-файл
helm install podinfo ./podinfo -n <ns> -f ./podinfo/values-prod.yaml

# сравнить dev и prod без кластера
diff <(helm template podinfo ./podinfo) <(helm template podinfo ./podinfo -f ./podinfo/values-prod.yaml)
```

## Хуки Helm

`хук (hook)` — ресурс с аннотацией `helm.sh/hook`, который Helm создаёт **не вместе** с остальными манифестами, а в определённый момент жизненного цикла релиза, и **ждёт его завершения** (для Job — до `Complete`). Типичные применения: миграции БД перед upgrade, бэкап перед удалением, уведомление после деплоя.

| Событие | Когда выполняется |
|---|---|
| `pre-install` | после рендера, **до** создания ресурсов релиза |
| `post-install` | после создания всех ресурсов (с `--wait` — после их готовности) |
| `pre-upgrade` | после рендера, до обновления ресурсов |
| `post-upgrade` | после обновления всех ресурсов |
| `pre-rollback` | до отката ресурсов |
| `post-rollback` | после отката |
| `pre-delete` | при `helm uninstall`, до удаления ресурсов |
| `post-delete` | после удаления всех ресурсов релиза |
| `test` | только по команде `helm test` |

| Аннотация | Значение |
|---|---|
| `helm.sh/hook` | одно или несколько событий через запятую |
| `helm.sh/hook-weight` | порядок внутри одного события (строка, по возрастанию, можно отрицательные) |
| `helm.sh/hook-delete-policy` | когда удалять ресурс хука (см. ниже) |

| Политика удаления | Что делает |
|---|---|
| `before-hook-creation` | удалить предыдущий экземпляр перед созданием нового (**по умолчанию**; без неё повторный хук с тем же именем упадёт с `already exists`) |
| `hook-succeeded` | удалить сразу после успешного выполнения |
| `hook-failed` | удалить, если хук упал (обычно **не** ставят — нужны логи для разбора) |

> **Ресурсы хуков не входят в релиз.** Helm не отслеживает их как часть релиза и не удаляет при `uninstall` — только по `hook-delete-policy`. Без политики удаления Job'ы хуков копятся в namespace.

### templates/hooks.yaml

Восемь событий — восемь почти одинаковых Job. Вместо восьми файлов — один шаблон с `range` по списку событий из values:

```yaml
{{- if .Values.hooks.enabled }}
{{- range $event := .Values.hooks.events }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "podinfo.fullname" $ }}-hook-{{ $event }}
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "podinfo.commonLabels" $ | nindent 4 }}
    app.kubernetes.io/component: hook
  annotations:
    helm.sh/hook: {{ $event }}
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: {{ $.Values.hooks.deletePolicy }}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        {{- include "podinfo.commonLabels" $ | nindent 8 }}
        app.kubernetes.io/component: hook
    spec:
      restartPolicy: Never
      containers:
        - name: hook
          image: {{ $.Values.hooks.image }}
          command:
            - sh
            - -c
            - echo "[{{ $event }}] release={{ $.Release.Name }} ns={{ $.Release.Namespace }} revision={{ $.Release.Revision }}"
{{- end }}
{{- end }}
```

* Внутри `range` точка — это строка события, поэтому весь доступ к релизу и values идёт через **`$`** (корневой контекст).
* `---` в начале каждой итерации — несколько документов в одном файле.
* `backoffLimit: 0` — упавший хук не перезапускается бесконечно; Helm сразу видит ошибку, и операция (install/upgrade) завершается с ошибкой.

### Как увидеть, что хуки создаются и удаляются

С политикой `hook-succeeded` Job живёт секунды. Смотреть во втором терминале:

```bash
kubectl get jobs -n <ns> -w                     # появление и исчезновение Job
kubectl get events -n <ns> --sort-by=.lastTimestamp | grep hook
helm get hooks podinfo -n <ns>                  # какие хуки есть в релизе
```

Чтобы прочитать логи хука, временно оставьте Job после выполнения:

```bash
helm upgrade podinfo ./podinfo -n <ns> -f ./podinfo/values-prod.yaml \
  --set hooks.enabled=true --set hooks.deletePolicy=before-hook-creation
kubectl logs -n <ns> job/podinfo-hook-pre-upgrade
# [pre-upgrade] release=podinfo ns=<ns> revision=3
```

| Событие | Как вызвать |
|---|---|
| `pre/post-install` | `helm install` |
| `pre/post-upgrade` | `helm upgrade` (хуки берутся из **нового** рендера — включили `hooks.enabled` в этом же upgrade → они сработают сразу) |
| `pre/post-rollback` | `helm rollback <release> <rev>` — выполняются хуки **целевой** ревизии: если в ней хуки были выключены, их не будет |
| `pre/post-delete` | `helm uninstall` — **только на отдельном тестовом релизе**, основной релиз по заданию удалять нельзя |

```bash
# отдельный одноразовый релиз для проверки delete-хуков
helm install hooks-demo ./podinfo -n <ns> --set hooks.enabled=true
helm uninstall hooks-demo -n <ns>
```

## Helm-тесты

`тест` — под (или Job) с аннотацией `helm.sh/hook: test`. Он создаётся только командой `helm test <release>`; **тест пройден, если контейнер завершился с кодом 0**, провален — при ненулевом коде или по таймауту. Тесты лежат в `templates/tests/`.

### Общий каркас: templates/tests/_pod.tpl

Четыре теста отличаются только именем и скриптом, поэтому метаданные, аннотации, образ и адрес сервиса вынесены в один `define`. Параметры передаются через `dict`:

```yaml
{{/*
Общий каркас тестового пода. Вызов:
  include "podinfo.testPod" (dict "ctx" $ "name" "http" "script" "...")
В скрипте доступна переменная $TARGET = http://<fullname>:<port>
*/}}
{{- define "podinfo.testPod" -}}
{{- $ctx := .ctx -}}
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "podinfo.fullname" $ctx }}-test-{{ .name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "podinfo.commonLabels" $ctx | nindent 4 }}
    app.kubernetes.io/component: test
  annotations:
    helm.sh/hook: test
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  restartPolicy: Never
  containers:
    - name: {{ .name }}
      image: {{ $ctx.Values.tests.image }}
      env:
        - name: TARGET
          value: {{ printf "http://%s:%v" (include "podinfo.fullname" $ctx) $ctx.Values.service.httpPort | quote }}
      command: ["sh", "-c"]
      args:
        - |
          {{- .script | trim | nindent 10 }}
{{- end }}
```

> `include` принимает **один** аргумент. Когда в именованный шаблон нужно передать и контекст, и свои параметры, их упаковывают в `dict`, а внутри достают как `.ctx`, `.name`, `.script`. Политика `before-hook-creation` оставляет под после прогона — можно прочитать логи, а при следующем `helm test` старый под удалится.

### Четыре теста

```yaml
# templates/tests/test-http.yaml — проверка HTTP API
{{- if .Values.tests.http.enabled }}
{{- include "podinfo.testPod" (dict "ctx" . "name" "http" "script" `
set -e
curl -sf "$TARGET/healthz"
curl -sf "$TARGET/version" | grep '"version"'
echo "HTTP API OK"
`) }}
{{- end }}
```

```yaml
# templates/tests/test-cache.yaml — запись/чтение через Redis
{{- if and .Values.redis.enabled .Values.tests.cache.enabled }}
{{- include "podinfo.testPod" (dict "ctx" . "name" "cache" "script" `
set -e
KEY="helm-test-$(date +%s)"
curl -sf -X POST -d "cached-value" "$TARGET/cache/$KEY"
curl -sf "$TARGET/cache/$KEY" | grep "cached-value"
curl -sf -X DELETE "$TARGET/cache/$KEY"
echo "CACHE OK"
`) }}
{{- end }}
```

```yaml
# templates/tests/test-fail.yaml — негативный сценарий: обязан упасть
{{- if .Values.tests.fail.enabled }}
{{- include "podinfo.testPod" (dict "ctx" . "name" "fail" "script" `
echo "ожидаем 2xx от /status/500 — тест обязан упасть"
curl -sf "$TARGET/status/500"
`) }}
{{- end }}
```

```yaml
# templates/tests/test-timeout.yaml — зависает дольше, чем helm test --timeout
{{- if .Values.tests.timeout.enabled }}
{{- include "podinfo.testPod" (dict "ctx" . "name" "timeout" "script" (printf `
echo "sleep %[1]v s — дольше, чем helm test --timeout"
sleep %[1]v
` .Values.tests.timeout.sleepSeconds)) }}
{{- end }}
```

* Скрипты записаны в обратных кавычках — это «сырые» строки Go-шаблонов: переносы строк, `"` и `$` внутри не нужно экранировать. `$TARGET` и `$(date)` раскроет уже `sh` в поде, а не Helm.
* `curl -f` — ключ к негативному тесту: при HTTP-коде ≥ 400 curl возвращает код выхода 22, контейнер завершается с ошибкой → тест провален.
* Cache-тест рендерится только при `redis.enabled=true`: без Redis кешу нечего проверять, и тест упал бы по причине конфигурации, а не бага.
* `%[1]v` в `printf` — один и тот же аргумент дважды.
* FAIL и TIMEOUT **выключены по умолчанию**: штатный `helm test` должен проходить, а негативные сценарии включаются осознанно, чтобы доказать, что проверка действительно ловит ошибку.

### Запуск

```bash
# штатный прогон: http (+ cache, если Redis включён) → Phase: Succeeded
helm test podinfo -n <ns> --logs

# только один тест
helm test podinfo -n <ns> --filter name=podinfo-test-cache

# FAIL-сценарий: включаем тест upgrade'ом и прогоняем
helm upgrade podinfo ./podinfo -n <ns> -f ./podinfo/values-prod.yaml --set tests.fail.enabled=true
helm test podinfo -n <ns>
# Error: 1 error occurred:
#   * pod podinfo-test-fail failed
kubectl logs -n <ns> podinfo-test-fail          # curl: (22) The requested URL returned error: 500

# TIMEOUT-сценарий
helm upgrade podinfo ./podinfo -n <ns> -f ./podinfo/values-prod.yaml --set tests.timeout.enabled=true
helm test podinfo -n <ns> --timeout 30s         # через 30 с — ошибка по таймауту
kubectl get pod -n <ns> podinfo-test-timeout    # STATUS Running — под действительно висит

# вернуть штатное состояние и прибрать тестовые поды
helm upgrade podinfo ./podinfo -n <ns> -f ./podinfo/values-prod.yaml
kubectl delete pod -n <ns> -l app.kubernetes.io/component=test
```

> Тестовые поды — тоже хуки, а не ресурсы релиза: `helm upgrade` их не удаляет. Отсюда `kubectl delete pod -l app.kubernetes.io/component=test` в конце — метка `component: test` для этого и нужна.

## Жизненный цикл: install → upgrade без простоя

### Как Helm выполняет upgrade

1. Рендерит шаблоны с новыми values.
2. Сравнивает **три** состояния: манифест прошлой ревизии, новый манифест, живые объекты в кластере — и отправляет патчи.
3. Ресурсы, которых **нет** в новом манифесте, но были в прошлом, — **удаляет**. Именно так исчезает Redis при `redis.enabled=false`: шаблоны отрендерились в пустоту → ConfigMap, Deployment и Service Redis удаляются.
4. Записывает новую ревизию (Secret `sh.helm.release.v1.<release>.v<N>`), старая становится `superseded`.

> Релиз **не удаляется и не ставится заново** — меняется только разница. Поэтому `helm uninstall` + `helm install` — неверный путь: теряется история ревизий и откат, и сервис лежит всё время между командами.

### Ловушка: upgrade без `-f` сбрасывает values

`helm upgrade` **не помнит** values прошлой ревизии: чего нет в команде — берётся из `values.yaml` чарта.

```bash
helm install podinfo ./podinfo -f values-prod.yaml         # prod
helm upgrade podinfo ./podinfo --set redis.enabled=false   # ОШИБКА: это уже dev-конфигурация без HPA, Ingress, ресурсов
helm upgrade podinfo ./podinfo -f values-prod.yaml --set redis.enabled=false   # правильно
```

| Флаг | Поведение |
|---|---|
| (по умолчанию) | values чарта + то, что передано в команде |
| `--reuse-values` | взять values прошлой ревизии + новые `--set` (но **не** новые умолчания из обновлённого values.yaml) |
| `--reset-values` | только values чарта + команда |
| `--reset-then-reuse-values` | новые умолчания чарта + values прошлой ревизии + команда (Helm ≥ 3.14) |

> Надёжнее всего всегда передавать `-f values-prod.yaml` явно — команда воспроизводима и не зависит от истории.

### Сценарий по заданию

```bash
NS=podinfo-<фамилия>          # namespace укажите в README / описании MR

# 0. проверки без кластера
helm lint ./podinfo --strict
helm lint ./podinfo --strict -f ./podinfo/values-prod.yaml
helm template podinfo ./podinfo -n $NS -f ./podinfo/values-prod.yaml > /dev/null

# 1. install prod (revision 1): Redis включён
helm install podinfo ./podinfo -n $NS --create-namespace \
  -f ./podinfo/values-prod.yaml --wait --timeout 5m
kubectl get deploy,svc,cm,hpa,pdb,ingress -n $NS
helm test podinfo -n $NS --logs                     # http + cache

# 2. во втором терминале — непрерывный опрос, чтобы доказать отсутствие простоя
kubectl run probe -n $NS --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'while true; do echo "$(date +%T) $(curl -s -o /dev/null -w %{http_code} http://podinfo:9898/healthz)"; sleep 0.5; done'

# 3. upgrade (revision 2): выключаем Redis
helm upgrade podinfo ./podinfo -n $NS \
  -f ./podinfo/values-prod.yaml --set redis.enabled=false --wait --timeout 5m

# 4. проверки
helm history podinfo -n $NS                         # 1 superseded, 2 deployed
kubectl get all,cm -n $NS -l app.kubernetes.io/component=redis   # No resources found
kubectl get deploy podinfo -n $NS -o jsonpath='{.spec.template.spec.containers[0].command}'  # нет --cache-server
helm test podinfo -n $NS                            # только http — cache-тест не рендерится
```

Во втором терминале всё время upgrade должны идти `200`. Почему простоя нет:

* изменение флагов (`--cache-server` пропал) меняет pod template → **rolling update**;
* `maxUnavailable: 0` + `readinessProbe` → старые поды удаляются только после готовности новых;
* `readinessProbe` podinfo (`/readyz`) не зависит от Redis — исчезновение кеша не делает поды NotReady;
* HPA держит `minReplicas: 3`, а `replicas` в Deployment нет — upgrade не сбрасывает число реплик.

```bash
helm history podinfo -n $NS
# REVISION  UPDATED   STATUS      CHART          APP VERSION  DESCRIPTION
# 1         ...       superseded  podinfo-0.1.0  6.7.1        Install complete
# 2         ...       deployed    podinfo-0.1.0  6.7.1        Upgrade complete
```

## Проверка без кластера: матрица рендера

Почти весь чек-лист проверяется `helm template` + `grep` — быстро и до похода в кластер:

```bash
C=./podinfo
helm template t $C | grep -E '^kind:'                                         # dev: Deployment, Service, тест-под
helm template t $C -f $C/values-prod.yaml | grep -E '^kind:' | sort | uniq -c # prod: + HPA, PDB, Ingress, Redis x3
helm template t $C --set hpa.enabled=true -s templates/deployment.yaml | grep replicas   # пусто
helm template t $C -s templates/deployment.yaml | grep -E 'cache-server|serviceAccountName|imagePullSecrets'  # пусто
helm template t $C --set redis.enabled=true | grep cache-server                # tcp://t-podinfo-redis:6379
helm template t $C -f $C/values-prod.yaml --set redis.enabled=false | grep -ci redis     # 0
helm template t $C --set service.type=NodePort --set service.nodePort=30080 -s templates/service.yaml
helm template t $C --set 'imagePullSecrets[0].name=regcred' -s templates/deployment.yaml | grep -A1 imagePullSecrets
helm template t $C --set hooks.enabled=true | grep -c 'helm.sh/hook:'          # 8 хуков + тесты

# негативные: рендер ОБЯЗАН упасть с понятным сообщением
helm template t $C --set pdb.enabled=true --set pdb.maxUnavailable=1          # задайте ровно одно из ...
helm template t $C --set ingress.enabled=true --set service.enabled=false      # ingress требует service
helm template t $C --set image.repository=                                     # image.repository обязателен
```

> Флаг `-s templates/<файл>` (`--show-only`) рендерит один шаблон — удобно смотреть на конкретный ресурс, не листая весь вывод.

## Сдача: ветка, README, Merge Request

```bash
git clone <url>/k8s-final-practice.git && cd k8s-final-practice
git switch -c feature/module8-podinfo-helm
mkdir -p module8 && cp -r <путь>/podinfo module8/
# ... README, проверки ...
git add module8 && git commit -m "module8: Helm-чарт podinfo"
git push -u origin feature/module8-podinfo-helm       # затем создать MR в интерфейсе GitLab
```

Шаблон `module8/README.md`:

````markdown
# module8 — Helm-чарт podinfo

**Namespace:** `podinfo-<фамилия>`

## Установка
```bash
helm install podinfo ./podinfo -n podinfo-<фамилия> --create-namespace -f ./podinfo/values-prod.yaml
```

## Upgrade-сценарий
```bash
helm upgrade podinfo ./podinfo -n podinfo-<фамилия> -f ./podinfo/values-prod.yaml --set redis.enabled=false
```

## helm list
```
<вывод helm list -n podinfo-<фамилия>>
```

## helm get values podinfo
```
<вывод helm get values podinfo -n podinfo-<фамилия>>
```

## helm history podinfo
```
<вывод>
```

## helm test podinfo
```
<вывод>
```
````

> `helm get values` покажет **USER-SUPPLIED VALUES** — ровно то, что пришло из `values-prod.yaml` и `--set`. Это и есть доказательство, что prod-релиз поставлен через override-файл.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `field is immutable` при upgrade | в `selector` попала меняющаяся метка (`version`, `helm.sh/chart`) | в selector только `name`, `instance`, `component` |
| Service podinfo иногда отвечает ошибкой соединения | selector Service совпадает с подом Redis (нет `component`) | разные `component` у приложения и Redis |
| HPA и Deployment «спорят» о числе реплик | `replicas` выводится при включённом HPA | `{{- if not .Values.hpa.enabled }}` |
| `kubectl get hpa` → `<unknown>` | нет metrics-server или `resources.requests` | включить metrics-server, задать requests |
| Поменяли `redis.config`, Redis работает по-старому | ConfigMap изменился, под не перезапустился | аннотация `checksum/config` |
| PDB с `minAvailable: 0` отрендерился без поля | `0` — «ложь» в `if` | проверка через `kindIs "invalid"` / сравнение с `""` |
| После upgrade пропали HPA и Ingress | upgrade без `-f values-prod.yaml` | всегда передавать override-файл |
| Хук: `jobs.batch "...-hook-pre-upgrade" already exists` | Job от прошлого запуска не удалён | `before-hook-creation` в delete-policy |
| `helm test` проходит, хотя сервис сломан | в скрипте `curl` без `-f` | `curl -sf` + `set -e` |
| `nil pointer evaluating .Values...` внутри `range` | в цикле `.` — элемент списка | `$.Values...` или переменная до цикла |
| Redis не удалился при `redis.enabled=false` | ресурс Redis создан вне релиза (`kubectl apply`) или как хук | все ресурсы Redis — обычные шаблоны чарта |

## Чек-лист → где это в конспекте

| Пункт задания | Раздел |
|---|---|
| `_helpers.tpl`, имена, labels, namespace | [_helpers.tpl](#_helperstpl) |
| values как интерфейс, `*.enabled` | [values.yaml как интерфейс](#valuesyaml) |
| `replicas`/HPA, SA, `imagePullSecrets`, `--cache-server` | [Deployment](#deployment) |
| условные порты, NodePort, selector | [Service](#service) |
| className, TLS, backend | [Ingress](#ingress) |
| CPU/memory, конфликт с `replicaCount` | [HPA](#hpa) |
| `minAvailable` / `maxUnavailable` | [PDB](#pdb) |
| Recreate, checksum, DNS `<fullname>-redis` | [Redis](#redis) |
| dev vs prod | [values-prod.yaml](#values-prodyaml) |
| install → upgrade, revision, удаление Redis | [Жизненный цикл](#install-upgrade) |
| хуки, delete-policy | [Хуки Helm](#helm) |
| http / cache / fail / timeout | [Helm-тесты](#helm-) |

> Базовые команды — [Helm: шпаргалка](helm-cheatsheet.md). Объекты Kubernetes (HPA, PDB, пробы, Ingress) — [Kubernetes (теория)](k8s.md).
