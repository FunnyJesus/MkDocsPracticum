# Карта: где какой параметр в манифесте и в Helm

> Практика на своём чарте — [Практикум: Helm на k8s-platform-lab](helm-practice.md). Объекты Kubernetes — [K8s](k8s.md). Основы Helm — [Helm](helm.md), [production-ready чарт](helm-podinfo.md).

Чтобы не гадать, куда вписать параметр, нужно держать в голове три карты:

1. **Вложенность объекта** — на каком уровне живёт поле (Deployment → под → контейнер).
2. **Связи между объектами** — кто на кого ссылается по имени, метке или порту.
3. **Путь значения в Helm** — `values.yaml` → строка шаблона → место в итоговом манифесте.

Ниже — все три, с примерами из чарта `k8s-platform-lab/charts/app`.

## Любой манифест: четыре поля верхнего уровня

```yaml
apiVersion: apps/v1        # группа/версия API — из документации или kubectl explain
kind: Deployment           # тип объекта
metadata:                  # кто это: name, namespace, labels, annotations
  name: app
spec:                      # что хотим получить — у каждого kind своё
  ...
# status: ...              # заполняет Kubernetes, сами не пишем
```

`metadata` устроен одинаково у всех объектов. `spec` — у каждого свой, его и нужно знать.

## Где взять правильную структуру, а не вспоминать

```bash
# 1. сгенерировать скелет — kubectl сам расставит уровни
kubectl create deployment app --image=nginx --port=8000 --dry-run=client -o yaml
kubectl create service clusterip app --tcp=80:8000 --dry-run=client -o yaml
kubectl create configmap app --from-literal=LOG_LEVEL=INFO --dry-run=client -o yaml
kubectl create ingress app --rule="app.localhost/*=app:80" --dry-run=client -o yaml

# 2. посмотреть, какие поля бывают на уровне (нужен запущенный кластер — kind подойдёт)
kubectl explain deployment.spec
kubectl explain deployment.spec.template.spec              # уровень пода
kubectl explain deployment.spec.template.spec.containers   # уровень контейнера
kubectl explain pod.spec.containers.resources --recursive  # всё дерево поля

# 3. подсмотреть у работающего объекта
kubectl get deployment app -n app -o yaml
```

> `kubectl explain` — главный инструмент. Не знаешь, где `tolerations`? `kubectl explain pod.spec.tolerations` — значит, на уровне пода (`template.spec`), а не контейнера.

## Карта 1. Вложенность Deployment

```
Deployment
├── metadata                         ← САМ Deployment: name, labels, annotations
└── spec                             ← уровень Deployment
    ├── replicas                       сколько подов (не пишем, если есть HPA)
    ├── selector.matchLabels           каких подов «мои» — НЕИЗМЕНЯЕМ после создания
    ├── strategy                       RollingUpdate: maxSurge / maxUnavailable
    ├── revisionHistoryLimit
    └── template                     ← ШАБЛОН ПОДА
        ├── metadata                 ← метки и аннотации ПОДА
        │   ├── labels                 должны включать selector.matchLabels
        │   └── annotations            checksum/config, prometheus.io/scrape
        └── spec                     ← уровень ПОДА (общее для всех контейнеров, планирование)
            ├── serviceAccountName
            ├── imagePullSecrets
            ├── securityContext        podSecurityContext: runAsUser, fsGroup, seccompProfile
            ├── terminationGracePeriodSeconds
            ├── nodeSelector / affinity / tolerations / topologySpreadConstraints
            ├── priorityClassName
            ├── volumes                ОБЪЯВЛЕНИЕ томов (emptyDir, configMap, secret, PVC)
            ├── initContainers[]       выполняются до основных
            └── containers[]         ← уровень КОНТЕЙНЕРА (один процесс)
                ├── name, image, imagePullPolicy
                ├── command / args
                ├── ports[]            containerPort + name
                ├── env[] / envFrom[]
                ├── resources          requests / limits
                ├── startupProbe / livenessProbe / readinessProbe
                ├── lifecycle          preStop / postStart
                ├── securityContext    readOnlyRootFilesystem, capabilities, allowPrivilegeEscalation
                └── volumeMounts[]     МОНТИРОВАНИЕ объявленных томов
```

### Правило уровней

| Вопрос | Уровень | Примеры |
|---|---|---|
| Касается **всего Deployment** (сколько, как обновлять)? | `spec` | `replicas`, `strategy`, `selector` |
| Касается **пода целиком**: где запускать, от чьего имени, общие тома? | `spec.template.spec` | `nodeSelector`, `tolerations`, `affinity`, `serviceAccountName`, `volumes`, `imagePullSecrets`, `terminationGracePeriodSeconds` |
| Касается **одного процесса**: образ, ресурсы, проверки, переменные? | `containers[]` | `image`, `resources`, `env`, пробы, `ports`, `volumeMounts`, `lifecycle` |
| Это **метка или аннотация** пода (для Service, Prometheus, перезапуска)? | `spec.template.metadata` | `labels`, `annotations` |

### Парные параметры — два уровня

Самые частые ошибки — с параметрами, у которых есть «половинки» на разных уровнях:

| Параметр | Уровень пода (`template.spec`) | Уровень контейнера (`containers[]`) |
|---|---|---|
| Тома | `volumes:` — **что** за том | `volumeMounts:` — **куда** смонтировать |
| securityContext | `runAsUser`, `runAsGroup`, `fsGroup`, `seccompProfile`, `runAsNonRoot` | `readOnlyRootFilesystem`, `capabilities`, `allowPrivilegeEscalation` (и может переопределить `runAsUser`) |
| Секреты | `imagePullSecrets` — чтобы скачать образ | `env.valueFrom.secretKeyRef` / `envFrom.secretRef` — чтобы передать процессу |

```yaml
spec:
  template:
    spec:
      volumes:                     # уровень пода: объявили
        - name: tmp
          emptyDir: {}
      containers:
        - name: app
          volumeMounts:            # уровень контейнера: смонтировали
            - name: tmp            # имя совпадает с volumes[].name
              mountPath: /tmp
```

### Метки: три места

```yaml
metadata:
  labels:                          # 1. метки Deployment — для людей и поиска (kubectl get deploy -l ...)
    app.kubernetes.io/name: app
spec:
  selector:
    matchLabels:                   # 2. каких подов Deployment считает своими
      app.kubernetes.io/name: app
      app.kubernetes.io/instance: app
  template:
    metadata:
      labels:                      # 3. метки пода — ДОЛЖНЫ содержать всё из selector.matchLabels
        app.kubernetes.io/name: app
        app.kubernetes.io/instance: app
        app.kubernetes.io/version: "0.1.0"   # можно больше, чем в selector
```

> В selector кладут только **стабильные** метки (`name`, `instance`). Версию — нельзя: selector нельзя изменить у существующего Deployment, и при смене версии `helm upgrade` упадёт с `field is immutable`. Поэтому в чарте два хелпера: `app.selectorLabels` (только стабильные) и `app.labels` (все).

## Остальные объекты чарта

### Service

```
Service
├── metadata
└── spec
    ├── type                 ClusterIP / NodePort / LoadBalancer
    ├── selector             метки ПОДОВ (не Deployment!)
    └── ports[]
        ├── name             http — на него ссылаются ServiceMonitor, Ingress (по номеру/имени)
        ├── port             порт Service (80) — на него ходят клиенты
        └── targetPort       порт контейнера: число (8000) или ИМЯ (http)
```

### Ingress

```
Ingress
├── metadata.annotations     настройки контроллера (nginx.ingress.kubernetes.io/...)
└── spec
    ├── ingressClassName     какой контроллер обрабатывает (nginx)
    ├── tls[]                hosts + secretName
    └── rules[]
        ├── host
        └── http.paths[]
            ├── path, pathType
            └── backend.service
                ├── name     имя Service
                └── port.number / port.name   порт SERVICE (80), не контейнера
```

### HPA, PDB, ConfigMap, Secret, ServiceAccount

```
HorizontalPodAutoscaler (autoscaling/v2)
└── spec
    ├── scaleTargetRef       apiVersion + kind + name Deployment
    ├── minReplicas / maxReplicas
    └── metrics[]            type: Resource → resource.name: cpu → target.averageUtilization: 70

PodDisruptionBudget (policy/v1)
└── spec
    ├── minAvailable / maxUnavailable   (одно из двух)
    └── selector.matchLabels            метки подов

ConfigMap                    Secret                       ServiceAccount
└── data:                    ├── type: Opaque             └── automountServiceAccountToken
    KEY: "строка"            └── stringData:                  (на верхнем уровне, не в spec!)
                                 KEY: "строка"
```

> У ConfigMap, Secret и ServiceAccount **нет** `spec` — данные лежат прямо на верхнем уровне (`data`, `stringData`, `automountServiceAccountToken`). Частая ошибка — написать `spec: data: ...`.

## Карта 2. Кто на кого ссылается

```
                    ┌────────────────────────── Ingress ──────────────────────────┐
                    │ backend.service.name: app       backend.service.port: 80    │
                    └──────────────┬──────────────────────────────┬───────────────┘
                                   │ имя                          │ номер
                    ┌──────────────▼──────────────────────────────▼───────────────┐
 ServiceMonitor ───►│ Service  metadata.name: app     ports: port 80, name http   │
 selector → метки   │          selector: {name, instance}       targetPort: http  │
 Service, port: http└──────────────┬──────────────────────────────┬───────────────┘
                                   │ метки                        │ имя порта
                    ┌──────────────▼──────────────────────────────▼───────────────┐
 PDB selector ─────►│ Pod  labels: {name, instance, ...}   ports: name http, 8000 │
 (метки)            │      envFrom.configMapRef.name: app ──────► ConfigMap app   │
                    │      secretKeyRef.name: app ──────────────► Secret app      │
                    │      serviceAccountName: app ─────────────► ServiceAccount  │
                    └──────────────▲──────────────────────────────────────────────┘
                                   │ template
 HPA scaleTargetRef.name: app ───► Deployment app (selector = метки пода)
```

| Связь | Чем связаны | Что будет, если не совпало | Как проверить |
|---|---|---|---|
| Service → поды | `selector` = метки пода | Service без endpoints → 503 от Ingress | `kubectl get endpoints app -n app` — пусто? |
| Service → порт контейнера | `targetPort: http` = `ports[].name` | endpoints пустые / connection refused | `kubectl describe svc app` → Endpoints |
| Ingress → Service | `backend.service.name` + `port.number` = `metadata.name` + `ports[].port` | 503 / `service not found` в логах контроллера | `kubectl describe ingress app` |
| Deployment → поды | `selector.matchLabels` ⊂ `template.metadata.labels` | ошибка при создании: `selector does not match template labels` | `helm template` + `kubectl apply --dry-run=server` |
| HPA → Deployment | `scaleTargetRef.name` | HPA `unknown`, не масштабирует | `kubectl describe hpa` |
| PDB → поды | `selector` = метки пода | PDB не защищает ничего (`ALLOWED DISRUPTIONS` странный) | `kubectl get pdb` |
| Под → ConfigMap/Secret | `configMapRef.name` / `secretKeyRef.name` + `key` | под в `CreateContainerConfigError` | `kubectl describe pod` → Events |
| ServiceMonitor → Service | `selector` = метки **Service**, `endpoints.port` = **имя** порта Service | Prometheus не видит цель | Prometheus → Status → Targets |

> Helm и `helm lint` эти связи **не проверяют** — шаблон с `targetPort: web` при порте `http` отрендерится без ошибок. Поэтому все имена и метки в чарте берутся из хелперов (`include "app.fullname"`, `include "app.selectorLabels"`), а не пишутся руками в нескольких местах.

## Карта 3. Путь значения в Helm

У каждого параметра три точки. Пример — `resources` из твоего чарта:

```
① values.yaml                        ② templates/deployment.yaml               ③ итоговый манифест (helm template)
resources:                           {{- with .Values.resources }}            spec:
  requests:                          resources:                                 template:
    cpu: 100m        ──────────────►   {{- toYaml . | nindent 12 }}  ────────►    spec:
    memory: 128Mi                    {{- end }}                                     containers:
                                                                                    - resources:
                                                                                        requests:
                                                                                          cpu: 100m
```

| Значение в values | Строка шаблона | Путь в итоговом манифесте |
|---|---|---|
| `image.repository`, `image.tag` | `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"` | `spec.template.spec.containers[0].image` |
| `resources` | `toYaml . | nindent 12` под `resources:` | `...containers[0].resources` |
| `readinessProbe` | `toYaml . | nindent 12` под `readinessProbe:` | `...containers[0].readinessProbe` |
| `podSecurityContext` | `toYaml . | nindent 8` под `securityContext:` на уровне пода | `spec.template.spec.securityContext` |
| `securityContext` | `toYaml . | nindent 12` под контейнерным `securityContext:` | `...containers[0].securityContext` |
| `config.LOG_LEVEL` | `range $k, $v := .Values.config` в configmap.yaml | ConfigMap `data.LOG_LEVEL` → в под через `envFrom` |
| `replicaCount` | `{{- if not .Values.autoscaling.enabled }} replicas: ...` | `spec.replicas` — **только если HPA выключен** |
| `podAnnotations` | `toYaml . | nindent 8` под `template.metadata.annotations` | `spec.template.metadata.annotations` |

> Имена ключей в `values.yaml` — **любые**, их придумывает автор чарта. Kubernetes их никогда не видит. Значение начинает что-то значить только тогда, когда шаблон поставит его на нужный уровень манифеста. Поэтому сначала решаешь, **где в манифесте** должно оказаться поле (карта 1), а потом — как назвать ключ в values и какой строкой шаблона его туда перенести.

### Как считать nindent

`nindent N` — перевести строку и сдвинуть каждую строку вставки на `N` пробелов. Правило:

> **N = отступ строки с ключом + 2.**

Линейка по твоему `deployment.yaml`:

```
0   apiVersion / kind / metadata / spec
2     name / labels: ............................... labels → nindent 4
2     replicas / selector / template
4       matchLabels: ............................... → nindent 6
4       metadata / spec (пода)
6         annotations: / labels: ................... → nindent 8
6         securityContext: / volumes: / nodeSelector: (уровень пода) → nindent 8
6         containers:
8           - name: app ............................ элемент списка контейнеров (extraContainers → nindent 8)
10            resources: / securityContext: / readinessProbe: / env: → nindent 12
12              requests: / - name: APP_VERSION
```

Проверка: отрендерь только один файл и посмотри глазами.

```bash
helm template app charts/app --show-only templates/deployment.yaml
```

### toYaml, простое значение и quote

| Что вставляем | Как | Пример |
|---|---|---|
| Словарь или список целиком | `toYaml . | nindent N` | `resources`, пробы, `tolerations`, `nodeSelector` |
| Одно число | как есть | `replicas: {{ .Values.replicaCount }}` |
| Одна строка | **`| quote`** | `value: {{ .Values.logLevel | quote }}` |
| Строка внутри строки | в кавычках в шаблоне | `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"` |

**Почему `quote` важен.** YAML сам угадывает тип: `on`, `off`, `yes`, `true` становятся булевыми, `1.10` — числом `1.1`, `0123` — числом. Поля Kubernetes вроде `env[].value`, `ConfigMap.data`, аннотации — **только строки**:

```yaml
# values.yaml: featureFlag: "on"       ← в values это строка
value: {{ .Values.featureFlag }}       # отрендерится: value: on   → Kubernetes увидит bool → ошибка
value: {{ .Values.featureFlag | quote }}   # value: "on"  → правильно
```

### Управляющие конструкции

| Конструкция | Что делает | Пример из чарта |
|---|---|---|
| `{{- if .Values.x.enabled }} ... {{- end }}` | включить блок или целый объект | `hpa.yaml`, `pdb.yaml`, `ingress.yaml` |
| `{{- with .Values.x }} ... {{- end }}` | если значение не пустое — вставить и **сменить `.` на это значение** | `with .Values.resources` → внутри `.` = resources |
| `{{- range .Values.list }} ... {{- end }}` | цикл; внутри `.` = текущий элемент | `range .Values.ingress.hosts` |
| `{{- range $k, $v := .Values.map }}` | цикл по словарю | ConfigMap из `config` |
| `$` | корень контекста — доступен **всегда**, даже внутри `with`/`range` | `include "app.fullname" $` внутри `range` в ingress.yaml |
| `{{ include "app.labels" . }}` | вставить хелпер из `_helpers.tpl` | метки, имена |
| `default "x" .Values.y` | значение по умолчанию | `image.tag | default .Chart.AppVersion` |
| `required "msg" .Values.y` | упасть с понятной ошибкой, если не задано | `{{ required "image.repository обязателен" .Values.image.repository }}` |
| `{{-` / `-}}` | удалить пробелы и перевод строки слева / справа | почти всегда `{{-` в начале строки |

**Главная ловушка — смена `.` внутри `with` и `range`:**

```yaml
{{- with .Values.ingress }}
ingressClassName: {{ .className }}            # ✓ . = .Values.ingress
port: {{ .Values.service.port }}              # ✗ внутри with нет .Values
port: {{ $.Values.service.port }}             # ✓ $ — корень
{{- end }}
```

Ошибка в первом случае (настоящая, из `helm template`):

```
Error: app/templates/ingress.yaml:14:47
  executing "app/templates/ingress.yaml" at <.Values.service.port>:
    nil pointer evaluating interface {}.service
```

### Как сливаются values

Порядок приоритета (последний побеждает):

```
values.yaml чарта  <  -f values-prod.yaml  <  -f values-local.yaml  <  --set key=value
```

| Тип | Как сливается | Пример |
|---|---|---|
| **Словарь (map)** | **рекурсивно**, по ключам | в prod задал только `resources.limits.memory` — `limits.cpu` останется из values.yaml |
| **Список** | **заменяется целиком** | `ingress.hosts` в prod полностью заменяет список из values.yaml |
| `null` | **удаляет** ключ | `resources: {limits: {cpu: null}}` — убрать лимит CPU |

```bash
helm template app charts/app -f values-prod.yaml --show-only templates/deployment.yaml   # посмотреть итог
helm get values app -n app            # что передали в установленный релиз
helm get values app -n app --all      # вместе со значениями по умолчанию
```

### Точки расширения

Хороший чарт заранее даёт «пустые» ключи для типовых настроек — тогда для новой настройки не нужно править шаблон:

| Ключ в values | Куда попадает |
|---|---|
| `podAnnotations`, `podLabels` | `spec.template.metadata` |
| `nodeSelector`, `tolerations`, `affinity` | `spec.template.spec` |
| `extraEnv` | `containers[0].env` |
| `extraVolumes` / `extraVolumeMounts` | `template.spec.volumes` / `containers[0].volumeMounts` |
| `extraContainers`, `initContainers` | `template.spec.containers` / `initContainers` |
| `serviceAccount.annotations` | ServiceAccount `metadata.annotations` |
| `ingress.annotations` | Ingress `metadata.annotations` |

Прежде чем менять шаблон, проверь, нет ли уже такой точки: многие задачи решаются **только правкой values**.

## Алгоритм: добавляю новый параметр

1. **Где в манифесте?** `kubectl explain <путь>` — найти уровень (Deployment / под / контейнер / другой объект).
2. **Есть ли точка расширения?** Если есть — только values, шаг 4.
3. **Шаблон:** найти в шаблоне соседнее поле того же уровня, вставить рядом. Словарь/список — `with` + `toYaml | nindent (отступ+2)`, строка — `quote`, опциональное — `if`/`with`.
4. **Values:** добавить ключ со значением по умолчанию (пустое `{}` / `[]` или безопасное) и комментарием.
5. **Проверить:**

```bash
helm lint charts/app
helm template app charts/app --show-only templates/deployment.yaml     # глазами: тот ли уровень
helm template app charts/app --set key=value | kubectl apply --dry-run=server -f -   # валидация API-сервером (нужен кластер)
helm upgrade --install app charts/app -n app --wait && helm test app -n app
kubectl get deploy app -n app -o yaml | yq '.spec.template.spec'        # что реально в кластере
```

## Инструменты, чтобы не угадывать

| Инструмент | Что даёт |
|---|---|
| `kubectl explain` | документация по любому полю, показывает уровень и тип |
| `kubectl create ... --dry-run=client -o yaml` | правильный скелет объекта |
| `helm template --show-only` | итог одного шаблона |
| `helm template --debug` | показать даже невалидный YAML, чтобы найти строку с ошибкой |
| `kubectl apply --dry-run=server` | API-сервер проверит манифест, ничего не создавая |
| `kubectl diff -f -` | что изменится в кластере |
| `kubeconform` | валидация по схемам без кластера (удобно в CI): `helm template ... | kubeconform -strict -summary` |
| VS Code + расширение **YAML** (Red Hat) | автодополнение и подсветка ошибок по схеме Kubernetes прямо в редакторе |
| `values.schema.json` в чарте | Helm сам проверит типы и обязательные поля values |

```json
// .vscode/settings.json — подсказки по схеме Kubernetes для манифестов (не для шаблонов Helm)
{
  "yaml.schemas": {
    "kubernetes": ["k8s/**/*.yaml"]
  }
}
```

> Для файлов в `templates/` схема не помогает: внутри `{{ }}` это не YAML. Там основной инструмент — `helm template` + глаза + `kubectl apply --dry-run=server`.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `YAML parse error ... mapping values are not allowed in this context` | `toYaml` вставлен без `nindent` в одну строку с ключом | `key:` на отдельной строке, ниже `{{- toYaml . | nindent N }}` |
| `helm template` прошёл, kubectl ругается `unknown field "spec.template.spec.containers[0].limits"` | неверный `nindent`: содержимое `resources` уехало на уровень выше | N = отступ ключа + 2, проверить `--show-only` |
| `nil pointer evaluating interface {}.service` | `.Values` внутри `with`/`range` | `$.Values...` |
| `cannot unmarshal bool into ... of type string` | строка `on`/`true`/`yes` без `quote` | `| quote` |
| `selector does not match template labels` | метки пода не содержат все метки selector | одни хелперы для обоих мест |
| `field is immutable` при `helm upgrade` | изменились метки в `selector` | в selector только стабильные метки |
| Под есть, Service без endpoints | не совпали метки или имя порта | `kubectl get endpoints`, сверить `selector` и `targetPort` |
| Параметр «не применился» | вписан не на тот уровень (например, `tolerations` в контейнер) | `kubectl explain`, затем `kubectl get ... -o yaml` |
| `CreateContainerConfigError` | ConfigMap/Secret/ключ с таким именем не существует | `kubectl describe pod`, имена через `include "app.fullname"` |
