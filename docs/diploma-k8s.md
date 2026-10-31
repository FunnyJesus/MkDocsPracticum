# Диплом: образы, Helm и кластер

Docker-образы, Helm-чарт приложения и платформенные компоненты кластера Momo Store.
Общий обзор — [на главной странице раздела](diploma-momo-store.md).

## Docker-образы

### Backend: multi-stage → distroless

```dockerfile
# syntax=docker/dockerfile:1

# go.mod требует go >= 1.23; собираем актуальным Go 1.25 — исправления безопасности stdlib
FROM golang:1.25-alpine AS build
WORKDIR /src

# зависимости — отдельным слоем, кэшируются между сборками
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w" \
      -o /out/api ./cmd/api

# distroless: без shell и пакетного менеджера, non-root (uid 65532)
FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION=dev
LABEL org.opencontainers.image.title="momo-backend" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=build /out/api /api
EXPOSE 8081
USER nonroot:nonroot
ENTRYPOINT ["/api"]
```

| Приём | Зачем |
|---|---|
| `go.mod`/`go.sum` отдельно от кода | при правке кода не перекачиваются зависимости |
| `CGO_ENABLED=0` | статический бинарник — работает в образе без libc |
| `-trimpath -ldflags="-s -w"` | без путей сборщика и отладочной информации — бинарник меньше |
| `distroless/static:nonroot` | нет shell → нечего эксплуатировать; ~20 МБ итог |
| Go 1.25 при `go 1.23` в `go.mod` | `go` в `go.mod` — **минимальная** версия; новее можно, и `go.mod` не меняется |

`.dockerignore` по принципу «запретить всё, разрешить нужное»:

```
*
!go.mod
!go.sum
!cmd/
!internal/
```

### Frontend: multi-stage → nginx-unprivileged

```dockerfile
FROM node:18-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# API — на том же домене по префиксу /api (проксирует nginx фронтенда)
ARG VUE_APP_API_URL=/api
ENV NODE_ENV=production VUE_APP_API_URL=${VUE_APP_API_URL}
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.29-alpine
ARG VERSION=dev
# исправления безопасности Alpine, которые ещё не попали в базовый образ
USER root
# hadolint ignore=DL3017
RUN apk upgrade --no-cache
USER 101
COPY nginx/default.conf nginx/common.inc /etc/nginx/conf.d/
COPY --from=build /app/dist /usr/share/nginx/html/momo-store
EXPOSE 8080
```

* `VUE_APP_*` подставляются **на этапе сборки** (vue-cli вшивает их в бандл) — поэтому `ARG`, а не env пода.
* `nginx-unprivileged` слушает 8080 и работает от uid 101 — порты < 1024 не нужны.
* `apk upgrade` — см. [журнал проблем: CVE в базовых образах](diploma-troubleshooting.md).

### Почему приложение живёт по `/momo-store/`

В исходном `frontend/vue.config.js` (менять нельзя):

```js
publicPath: process.env.NODE_ENV === 'production' ? '/momo-store/' : '/'
```

Бандл ищет JS/CSS по `/momo-store/js/...`, а vue-router использует `/momo-store/` как base.
Поэтому `dist` кладётся в `/usr/share/nginx/html/momo-store`, а nginx:

```nginx
location = / { return 302 /momo-store/; }

location ~* ^/momo-store/.+\.(?:js|css|woff2?|png|jpe?g|svg|ico)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";   # у файлов хэш в имени
    try_files $uri =404;
}

location /momo-store/ {
    add_header Cache-Control "no-cache";            # index.html не кэшируем
    try_files $uri $uri/ /momo-store/index.html;    # SPA: history mode
}

location = /healthz { access_log off; return 200 "ok\n"; }

location = /stub_status {                            # для nginx-prometheus-exporter
    stub_status;
    allow 127.0.0.1;
    deny all;
}
```

Общая часть вынесена в `common.inc` и подключается `include` — и в конфиг образа, и в конфиг из Helm.

### Локальная проверка образов

```bash
docker build -t momo-backend:test backend
docker run -d --name mb -p 18081:8081 momo-backend:test
curl -s localhost:18081/health -w '%{http_code}\n'
curl -s localhost:18081/metrics | head

# сканирование локального образа тем же trivy, что в CI
docker save momo-frontend:test -o fe.tar
docker run --rm -v $PWD:/s aquasec/trivy:0.67.2 image --input /s/fe.tar \
  --severity CRITICAL --ignore-unfixed --exit-code 1
```

## nginx фронтенда как шлюз к API

Требование «статика из S3» при запрете менять backend: backend отдаёт ссылки на Cloudinary
(`https://res.cloudinary.com/sugrobov/image/upload/v1651932686/repos/momos/<file>.jpg`).
Решение — nginx фронтенда **проксирует API и подменяет ссылки в ответе** (`sub_filter`).

Конфиг генерируется Helm'ом (ConfigMap `momo-store-frontend-nginx`):

```nginx
upstream backend {
    server momo-store-backend:8081;      # имя сервиса из Release.Name
    keepalive 16;
}

server {
    listen 8080;

    # /api/<resource> → backend /<resource>; публикуются ТОЛЬКО ресурсы API
    location ~ ^/api/(products|categories|orders|auth)(/|$) {
        rewrite ^/api/(.*)$ /$1 break;
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";          # для keepalive к upstream

        proxy_set_header Accept-Encoding "";     # sub_filter не работает со сжатым ответом
        sub_filter_types application/json;
        sub_filter_once off;                     # заменить все вхождения, не только первое
        sub_filter 'https://res.cloudinary.com/sugrobov/image/upload/v1651932686/repos/momos/'
                   'https://storage.yandexcloud.net/<static_bucket>/images/';
        sub_filter 'https://res.cloudinary.com/sugrobov/image/upload/v1651932687/repos/momos/'
                   'https://storage.yandexcloud.net/<static_bucket>/images/';
    }

    location /api/ { return 404; }               # /api/metrics, /api/health — закрыты

    include /etc/nginx/conf.d/common.inc;
}
```

| Деталь | Почему важно |
|---|---|
| `upstream` вместо `proxy_pass http://$var` | с переменной nginx резолвит имя в рантайме и требует `resolver`; с `upstream` — один раз при старте |
| `rewrite ... break` | отрезать `/api`, не уходя в поиск другого location |
| `Accept-Encoding ""` | иначе backend может прислать gzip, и `sub_filter` не увидит текст |
| Два префикса | у картинок в исходниках две разные «версии» Cloudinary (`v1651932686`, `v1651932687`) |
| Белый список ресурсов | `/metrics` и `/health` backend недоступны из интернета |

Проверка — все ссылки ведут в бакет:

```bash
curl -s http://<ingress_ip>/api/products | grep -o '"image":"[^"]*"' | sort -u
curl -s http://<ingress_ip>/api/products | grep -c cloudinary     # 0
```

!!! note "Компромисс"
    Подмена завязана на конкретные префиксы. Если в backend появятся картинки с другим префиксом —
    дописать его в `frontend.imagesRewrite.from` в values. В README это описано.

## Helm-чарт приложения

Umbrella-чарт `infrastructure/helm/momo-store`:

```
momo-store/
├── Chart.yaml                 # dependencies: backend, frontend (локальные сабчарты)
├── values.yaml                # global.registry, global.imageTag, ingress, networkPolicy
├── templates/
│   ├── ingress.yaml           # 2 Ingress → frontend: "/" и "/api"
│   ├── networkpolicy.yaml     # default-deny + явные разрешения
│   ├── dashboard.yaml         # ConfigMap с JSON дашборда (label grafana_dashboard: "1")
│   └── NOTES.txt
├── dashboards/momo-store-red.json  (+ generate.py)
└── charts/
    ├── backend/templates/   deployment, service, hpa, pdb, servicemonitor, _helpers
    └── frontend/templates/  + configmap (nginx), exporter-sidecar
```

### Версия и тег образа

```yaml
# _helpers.tpl сабчарта
{{- define "component.imageTag" -}}
{{- .Values.image.tag | default .Values.global.imageTag | required "image tag is required: set global.imageTag" -}}
{{- end }}
```

`required` — деплой без тега падает сразу с понятной ошибкой, а не тянет `:latest`.
CI передаёт `--set global.imageTag=0.1.0`, а `helm package --version 0.1.0 --app-version 0.1.0`
выставляет версию чарта.

### Deployment backend (главное)

```yaml
spec:
  # replicas не задаём, если включён HPA — иначе каждый helm upgrade сбрасывал бы число реплик
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }   # сначала поднять новый, потом убрать старый
  template:
    spec:
      automountServiceAccountToken: false               # токен API приложению не нужен
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      affinity:
        podAntiAffinity:                                # реплики — на разные узлы
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector: { matchLabels: { app.kubernetes.io/name: backend, ... } }
      containers:
        - name: backend
          readinessProbe: { httpGet: { path: /health, port: http }, periodSeconds: 5, failureThreshold: 3 }
          livenessProbe:  { httpGet: { path: /health, port: http }, initialDelaySeconds: 5, periodSeconds: 10 }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 250m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
```

Frontend отличается:

* второй контейнер — `nginx/nginx-prometheus-exporter` (порт 9113, читает `stub_status`);
* `emptyDir` в `/tmp` — nginx пишет туда pid и временные файлы при `readOnlyRootFilesystem`;
* ConfigMap монтируется через `subPath` в `/etc/nginx/conf.d/default.conf`;
* аннотация `checksum/nginx: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}` —
  поды перезапускаются при изменении конфига;
* `preStop: sleep 5` — ingress-nginx успевает убрать под из upstream до остановки nginx.

### HPA и PDB

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2
  maxReplicas: 5             # frontend — 4
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 300 }   # не «дёргать» реплики
---
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1            # drain узла не уберёт все реплики сразу
```

HPA по CPU работает только при заданных `resources.requests` — утилизация считается от request.

### ServiceMonitor — только если есть CRD

```yaml
{{- if and .Values.global.monitoring.enabled .Values.metrics.enabled
           (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor") }}
```

Чарт ставится и в кластер без prometheus-operator. В CI для `helm template` + kubeconform передаю
`--api-versions monitoring.coreos.com/v1/ServiceMonitor`, чтобы ServiceMonitor тоже отрендерился.

### Ingress

Два Ingress на **один** сервис frontend:

```yaml
{{- range $name, $path := dict "frontend" "/" "api" "/api" }}
# metadata.name: momo-store-frontend / momo-store-api, path: $path, backend: momo-store-frontend:http
{{- end }}
```

Зачем два: метрики ingress-nginx имеют метку `ingress` — так Errors/Duration считаются отдельно
для статики и для API. `host` пустой — доступ по IP; с доменом включается TLS через cert-manager.

### Проверка чарта

```bash
helm lint . --set global.imageTag=0.0.0-lint
helm template momo-store . -f ../values-prod.yaml --set global.imageTag=0.0.0-lint \
  --api-versions monitoring.coreos.com/v1/ServiceMonitor \
  | kubeconform -strict -summary -ignore-missing-schemas
# Summary: 18 resources - Valid: 16, Skipped: 2 (ServiceMonitor — CRD, схемы нет)
```

## Zero-trust: NetworkPolicy

```
            ingress-nginx ──:8080──► frontend ──:8081──► backend
            monitoring    ──:9113──► frontend (exporter)
            monitoring    ──:8081──────────────────────► backend (/metrics)
            все поды      ──:53────► kube-system/kube-dns
            всё остальное — запрещено
```

```yaml
# 1. запретить всё
kind: NetworkPolicy
metadata: { name: default-deny-all }
spec: { podSelector: {}, policyTypes: [Ingress, Egress] }
---
# 2. DNS для всех
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector:       { matchLabels: { k8s-app: kube-dns } }     # один элемент списка = И
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
---
# 3. frontend: вход от ingress-nginx и monitoring, выход — только в backend
# 4. backend:  вход только от frontend и monitoring
```

!!! tip "namespaceSelector + podSelector в одном элементе — это И"
    `- namespaceSelector: ...` и `podSelector: ...` **в одном** элементе `from/to` = «поды с такой меткой
    в таком namespace». Два отдельных элемента списка (`- namespaceSelector`, `- podSelector`) = ИЛИ.

Метку `kubernetes.io/metadata.name` Kubernetes ставит на каждый namespace автоматически.
Пробы kubelet ходят с узла — Calico такой трафик не блокирует.

Проверка (план на звёздочку):

```bash
kubectl run probe -n default --rm -it --image=curlimages/curl -- \
  curl -m 3 http://momo-store-backend.momo-store:8081/health     # timeout — заблокировано
```

## Платформа кластера: install.sh

`infrastructure/k8s-addons/install.sh` — идемпотентный (`helm upgrade --install`, `kubectl apply`,
`create --dry-run=client -o yaml | kubectl apply -f -`):

```bash
INGRESS_IP=$(terraform -chdir=../terraform/envs/prod output -raw ingress_ip) \
GRAFANA_PASSWORD="$(cat ~/.config/yandex-cloud/momo-grafana-password)" \
./install.sh
```

| Шаг | Что |
|---|---|
| 1 | namespaces `monitoring`, `ingress-nginx` |
| 2 | `preemptible-handler` (DaemonSet в `kube-system`) |
| 3 | Secret `grafana-admin` + **kube-prometheus-stack** 92.16.1, `--wait --timeout 15m` |
| 4 | **ingress-nginx** 4.15.1 с `loadBalancerIP` = статический IP |
| 5 | cert-manager + ClusterIssuer — только если задан `LETSENCRYPT_EMAIL` |
| 6 | namespace `momo-store` + SA `gitlab-deployer` с правами только в нём |

Порядок важен: сначала Prometheus (ставит CRD `ServiceMonitor`), потом ingress-nginx (создаёт свой ServiceMonitor).

### values ingress-nginx

```yaml
controller:
  replicaCount: 2
  service:
    externalTrafficPolicy: Local    # сохраняет IP клиента; NLB шлёт только на узлы с контроллером
  extraArgs:
    metrics-per-host: "false"       # иначе нет метрик запросов для Ingress без host
  metrics:
    enabled: true
    serviceMonitor: { enabled: true }
```

### values kube-prometheus-stack

```yaml
alertmanager: { enabled: false }            # экономия ресурсов
kubeEtcd: { enabled: false }                # control plane — у Yandex Cloud, недоступен для сбора
kubeScheduler: { enabled: false }
kubeControllerManager: { enabled: false }
kubeProxy: { enabled: false }

prometheus:
  prometheusSpec:
    retention: 3d
    serviceMonitorSelectorNilUsesHelmValues: false   # брать ServiceMonitor из всех namespace, без меток релиза
    podMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec: { storageClassName: yc-network-hdd, resources: { requests: { storage: 10Gi } } }

grafana:
  admin: { existingSecret: grafana-admin, userKey: admin-user, passwordKey: admin-password }
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/grafana/"
      serve_from_sub_path: true                       # Grafana по подпути /grafana
  ingress: { enabled: true, ingressClassName: nginx, path: /grafana, hosts: [] }
  sidecar:
    dashboards: { enabled: true, label: grafana_dashboard, searchNamespace: ALL }
  resources:
    requests: { memory: 256Mi }
    limits:   { memory: 512Mi }                       # 256Mi → OOMKilled
```

!!! warning "Без `serviceMonitorSelectorNilUsesHelmValues: false` Prometheus не увидит свои же ServiceMonitor"
    По умолчанию Prometheus выбирает только ServiceMonitor с меткой `release: kube-prometheus-stack`.

### Прерываемые узлы: preemptible-handler

Прерываемая ВМ живёт **не дольше 24 часов** и может быть остановлена в любой момент.
Yandex Cloud предупреждает примерно **за 30 секунд**: метаданные ВМ (GCE-совместимый endpoint)
начинают отвечать `TRUE`.

```bash
#!/bin/bash
METADATA_URL="http://169.254.169.254/computeMetadata/v1/instance/preempted"
ANNOTATION="preemptible-handler/drained"

# после перезапуска ВМ узел остался в cordon — снимаем, если ставили мы
if [ "$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.annotations.preemptible-handler/drained}")" = "true" ]; then
  kubectl uncordon "$NODE_NAME"
  kubectl annotate node "$NODE_NAME" "$ANNOTATION-"
fi

while true; do
  preempted=$(curl -sf -H "Metadata-Flavor: Google" "$METADATA_URL" || echo "")
  if [ "$preempted" = "TRUE" ]; then
    kubectl annotate node "$NODE_NAME" "$ANNOTATION=true" --overwrite
    kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force \
      --grace-period=15 --timeout=25s
    sleep infinity
  fi
  sleep 5
done
```

| Деталь манифеста | Зачем |
|---|---|
| `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` | доступ к 169.254.169.254 из сети узла |
| `nodeSelector: preemptible: "true"` | метка из Terraform (`node_labels`) |
| `tolerations: [{operator: Exists}]` | работать на любых узлах, в т.ч. с taint |
| `priorityClassName: system-node-critical` | не вытесняется при нехватке ресурсов |
| `NODE_NAME` из `fieldRef: spec.nodeName` | какой узел дренировать |
| `HOME=/tmp` + emptyDir | kubectl пишет discovery-кэш, а корень read-only |
| ClusterRole: nodes get/patch, pods list, pods/eviction create, apps get | минимум для `drain` |
| образ `alpine/k8s:1.34.5` | kubectl + curl + bash; версия kubectl = версия кластера (skew ±1) |

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=preemptible-handler
# ... [cl1...-amud] watching preemption notice
```

Вместе с ним работают: 2 реплики, `podAntiAffinity` (на разных узлах), PDB `minAvailable: 1`.

### Доступ CI к кластеру

```yaml
kind: ServiceAccount        # gitlab-deployer в namespace momo-store
---
kind: Secret                # долгоживущий токен (с 1.24 не создаётся автоматически)
type: kubernetes.io/service-account-token
metadata: { annotations: { kubernetes.io/service-account.name: gitlab-deployer } }
---
kind: RoleBinding           # ClusterRole admin, но только в namespace momo-store
---
kind: Role                  # admin не покрывает CRD prometheus-operator
rules: [{ apiGroups: [monitoring.coreos.com], resources: [servicemonitors, podmonitors, prometheusrules], verbs: ["*"] }]
```

`make-kubeconfig.sh` собирает kubeconfig из `server` текущего контекста, `ca.crt` и `token` секрета.
Проверка прав:

```bash
KUBECONFIG=~/.config/yandex-cloud/momo-kubeconfig-ci kubectl auth can-i create deployments -n momo-store   # yes
KUBECONFIG=~/.config/yandex-cloud/momo-kubeconfig-ci kubectl auth can-i get pods -n monitoring             # no
```

## Проверка после деплоя

```bash
kubectl -n momo-store get pods,hpa,pdb,networkpolicy,ingress

U=http://<ingress_ip>
curl -s -o /dev/null -w '%{http_code}\n' $U/                 # 302 → /momo-store/
curl -s -o /dev/null -w '%{http_code}\n' $U/momo-store/      # 200
curl -s $U/api/products | head -c 200                       # JSON, картинки из бакета
curl -s -X POST $U/api/orders                               # {"id":1}
curl -s -o /dev/null -w '%{http_code}\n' $U/api/metrics      # 404 — закрыто
```
