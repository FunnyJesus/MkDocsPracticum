# Практикум: Helm на k8s-platform-lab

> Справочник к задачам — [Карта: где какой параметр](k8s-yaml-map.md). Сначала прочитай её разделы «Карта 1» и «Карта 3».

Задачи идут от простых к сложным и делаются на твоём чарте `charts/app`. В каждой задаче **сначала сам реши**, на какой уровень манифеста идёт параметр и как пробросить его через values, и только потом открывай решение. Все решения проверены `helm lint` и `helm template` на копии твоего чарта.

## Как работать

```bash
cd ~/Documents/my_repo/k8s-platform-lab
git switch -c helm-practice              # отдельная ветка: можно ломать
```

После **каждой** задачи:

```bash
helm lint charts/app
helm template app charts/app --show-only templates/deployment.yaml    # нужный файл — глазами
```

Если кластер запущен (`make up`):

```bash
make deploy                               # или helm upgrade --install ...
kubectl get deploy app -n app -o yaml | yq '.spec.template.spec'
```

Формат задачи: **Цель** → **Подсказка** (уровень и файлы) → **Проверка** → решение под спойлером → **Почему так**.

---

## Задача 1. Трассировка: где оказывается значение

**Цель.** Ничего не менять — только найти путь. Для каждого значения из `values.yaml` найди строку в шаблоне и путь в итоговом манифесте.

| Значение | Строка шаблона (файл) | Путь в итоговом манифесте |
|---|---|---|
| `image.tag` | ? | ? |
| `resources.requests.cpu` | ? | ? |
| `readinessProbe.periodSeconds` | ? | ? |
| `config.LOG_LEVEL` | ? | ? |
| `replicaCount` | ? | ? |

**Проверка.**

```bash
helm template app charts/app > /tmp/render.yaml
grep -n "periodSeconds\|LOG_LEVEL\|replicas\|image:" /tmp/render.yaml
```

??? success "Решение"

    | Значение | Строка шаблона | Путь в итоговом манифесте |
    |---|---|---|
    | `image.tag` | `deployment.yaml`: `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"` | Deployment `spec.template.spec.containers[0].image` → `k8s-platform-lab:dev` |
    | `resources.requests.cpu` | `deployment.yaml`: `{{- with .Values.resources }}` + `toYaml . | nindent 12` | Deployment `spec.template.spec.containers[0].resources.requests.cpu` |
    | `readinessProbe.periodSeconds` | `deployment.yaml`: `{{- with .Values.readinessProbe }}` + `toYaml . | nindent 12` | `spec.template.spec.containers[0].readinessProbe.periodSeconds` |
    | `config.LOG_LEVEL` | `configmap.yaml`: `range $k, $v := .Values.config` | ConfigMap `data.LOG_LEVEL`, а в под — через `envFrom.configMapRef` в контейнере |
    | `replicaCount` | `deployment.yaml`: `{{- if not .Values.autoscaling.enabled }} replicas: ...` | **нигде** — у тебя `autoscaling.enabled: true`, реплики задаёт HPA (`minReplicas`) |

    **Почему так.** `replicaCount` — ловушка: значение есть в values, но в манифест не попадает. Когда включён HPA, `replicas` в Deployment не пишут, иначе каждый `helm upgrade` сбрасывал бы число подов, выставленное HPA. Проверь: `helm template app charts/app --set autoscaling.enabled=false | grep replicas`.

---

## Задача 2. Аннотации Prometheus на подах — без правки шаблона

**Цель.** Добавить подам аннотации `prometheus.io/scrape: "true"`, `prometheus.io/port: "8000"`, `prometheus.io/path: "/metrics"`.

**Подсказка.** Аннотации для **пода** — не на Deployment. Посмотри, нет ли в values готовой точки расширения.

**Проверка.**

```bash
helm template app charts/app --show-only templates/deployment.yaml | yq '.spec.template.metadata.annotations'
```

??? success "Решение"

    Только `values.yaml` — шаблон уже умеет:

    ```yaml
    podAnnotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8000"
      prometheus.io/path: "/metrics"
    ```

    В `deployment.yaml` это обрабатывает блок:

    ```yaml
    template:
      metadata:
        annotations:
          checksum/config: ...
          {{- with .Values.podAnnotations }}
          {{- toYaml . | nindent 8 }}
          {{- end }}
    ```

    **Почему так.** Prometheus через Kubernetes service discovery смотрит на аннотации **подов** (`role: pod`). Аннотации в `metadata` самого Deployment он не видит. Значения в кавычках: аннотации бывают только строками, а `true` без кавычек YAML превратит в bool.

---

## Задача 3. values-prod.yaml и правила слияния

**Цель.** Создать `charts/app/values-prod.yaml`:

* HPA: от 3 до 10 реплик;
* `requests`: cpu `250m`, memory `256Mi`; `limits.memory`: `512Mi`;
* Ingress с `className: nginx` и хостом `app.example.com`;
* `LOG_LEVEL: WARNING`.

**Вопрос до проверки:** какой будет `limits.cpu` в итоговом манифесте?

**Проверка.**

```bash
helm template app charts/app -f charts/app/values-prod.yaml --show-only templates/deployment.yaml | yq '.spec.template.spec.containers[0].resources'
helm template app charts/app -f charts/app/values-prod.yaml --show-only templates/configmap.yaml
```

??? success "Решение"

    ```yaml
    # charts/app/values-prod.yaml — только отличия от values.yaml
    autoscaling:
      minReplicas: 3
      maxReplicas: 10

    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        memory: 512Mi

    ingress:
      className: nginx
      hosts:
        - host: app.example.com
          paths:
            - path: /
              pathType: Prefix

    config:
      LOG_LEVEL: "WARNING"
    ```

    Результат:

    ```yaml
    resources:
      limits:
        cpu: 500m          # ← пришло из values.yaml!
        memory: 512Mi
      requests:
        cpu: 250m
        memory: 256Mi
    ```

    ConfigMap: `LOG_LEVEL: WARNING` и `READY_DELAY_SECONDS: "3"` (из values.yaml).

    **Почему так.** Словари сливаются **рекурсивно**: ты переопределил только `limits.memory`, `limits.cpu` остался из базовых values. То же с `config`: добавился/заменился один ключ, остальные на месте. А **списки заменяются целиком**: `ingress.hosts` из prod полностью вытеснил список из values.yaml. Чтобы **удалить** унаследованный ключ — `null`:

    ```yaml
    resources:
      limits:
        cpu: null          # убрать лимит CPU
    ```

---

## Задача 4. Дополнительные переменные окружения

**Цель.** Добавить в values список `extraEnv`, чтобы можно было передать любые переменные:

```yaml
extraEnv:
  - name: FEATURE_FLAG
    value: "on"
```

Переменные должны оказаться **рядом с `APP_VERSION`**.

**Подсказка.** Уровень контейнера, список `env`. Вставляешь элементы в **существующий** список — какой отступ у `- name: APP_VERSION`?

**Проверка.**

```bash
helm template app charts/app --set 'extraEnv[0].name=FEATURE_FLAG' --set 'extraEnv[0].value=on' \
  --show-only templates/deployment.yaml | yq '.spec.template.spec.containers[0].env'
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    extraEnv: []
    #  - name: FEATURE_FLAG
    #    value: "on"
    ```

    `deployment.yaml` — сразу после `APP_VERSION`:

    ```yaml
              env:
                - name: APP_VERSION
                  value: {{ .Chart.AppVersion | quote }}
              {{- with .Values.extraEnv }}
                {{- toYaml . | nindent 12 }}
              {{- end }}
              {{- if .Values.adminToken }}
                - name: ADMIN_TOKEN
    ```

    **Почему так.** `- name: APP_VERSION` стоит с отступом 12 — элементы списка `toYaml` должны начинаться там же, отсюда `nindent 12`. `with` не вставит ничего, если список пустой. А `"on"` в values в кавычках — иначе YAML прочитает его как `true`, и `toYaml` выведет bool, который Kubernetes не примет в `env[].value`.

---

## Задача 5. nodeSelector, tolerations, affinity

**Цель.** Дать возможность через values указывать, на каких нодах запускать поды.

```yaml
nodeSelector:
  kubernetes.io/os: linux
tolerations:
  - key: dedicated
    operator: Equal
    value: app
    effect: NoSchedule
```

**Подсказка.** `kubectl explain pod.spec.tolerations` — какой уровень? Найди в `deployment.yaml` соседа того же уровня (`terminationGracePeriodSeconds`, `serviceAccountName`).

**Проверка.**

```bash
helm template app charts/app --set 'nodeSelector.kubernetes\.io/os=linux' \
  --show-only templates/deployment.yaml | yq '.spec.template.spec.nodeSelector'
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    nodeSelector: {}
    tolerations: []
    affinity: {}
    ```

    `deployment.yaml` — после `terminationGracePeriodSeconds` (уровень пода, отступ 6):

    ```yaml
          terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
          {{- with .Values.nodeSelector }}
          nodeSelector:
            {{- toYaml . | nindent 8 }}
          {{- end }}
          {{- with .Values.tolerations }}
          tolerations:
            {{- toYaml . | nindent 8 }}
          {{- end }}
          {{- with .Values.affinity }}
          affinity:
            {{- toYaml . | nindent 8 }}
          {{- end }}
    ```

    **Почему так.** Где запускать — решение для **пода целиком**, планировщик не смотрит на отдельные контейнеры. Ключ на отступе 6 → содержимое `nindent 8`. В `--set` точку в ключе экранируют: `kubernetes\.io/os`, иначе Helm воспримет её как вложенность.

    Попробуй в kind: `kubectl taint nodes platform-lab-worker dedicated=app:NoSchedule` — без toleration поды на этот worker больше не встанут.

---

## Задача 6. Writable /tmp при readOnlyRootFilesystem

**Цель.** У тебя `readOnlyRootFilesystem: true` — контейнер не может писать никуда. Многие библиотеки пишут во временные файлы. Смонтируй `emptyDir` в `/tmp` с ограничением размера, включаемый флагом:

```yaml
tmpDir:
  enabled: true
  sizeLimit: 64Mi
```

**Подсказка.** Парный параметр: том **объявляется** на одном уровне, **монтируется** на другом (см. «Парные параметры» в карте).

**Проверка.**

```bash
helm template app charts/app --show-only templates/deployment.yaml | yq '.spec.template.spec.volumes, .spec.template.spec.containers[0].volumeMounts'
# в кластере:
kubectl exec -n app deploy/app -- sh -c 'touch /tmp/ok && echo tmp writable; touch /ok || echo root read-only'
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    tmpDir:
      enabled: true
      sizeLimit: 64Mi
    ```

    `deployment.yaml`, уровень пода (рядом с `nodeSelector`, отступ 6):

    ```yaml
          {{- if .Values.tmpDir.enabled }}
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: {{ .Values.tmpDir.sizeLimit }}
          {{- end }}
    ```

    Уровень контейнера (в конце контейнера, отступ 10):

    ```yaml
              {{- if .Values.tmpDir.enabled }}
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
              {{- end }}
    ```

    **Почему так.** `volumes` — свойство пода: том существует, пока жив под, и его можно смонтировать в несколько контейнеров. `volumeMounts` — свойство контейнера: куда именно в его файловой системе. Связаны они **именем** (`tmp`). `sizeLimit` защищает ноду: если приложение начнёт писать гигабайты в `/tmp`, под будет вытеснен, а не заполнит диск ноды.

---

## Задача 7. Перезапуск подов при смене Secret

**Цель.** Сейчас правка `config` перезапускает поды благодаря `checksum/config`. А смена `adminToken` — нет: Secret обновится, но поды продолжат работать со старым значением. Исправь.

**Подсказка.** Посмотри, как устроен `checksum/config` и где он стоит. Secret создаётся не всегда.

**Проверка.**

```bash
helm template app charts/app --set adminToken=one --show-only templates/deployment.yaml | grep checksum
helm template app charts/app --set adminToken=two --show-only templates/deployment.yaml | grep checksum   # хеш другой
helm template app charts/app --show-only templates/deployment.yaml | grep checksum                         # без токена — только config
```

??? success "Решение"

    `deployment.yaml`, в `template.metadata.annotations`:

    ```yaml
          annotations:
            checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
            {{- if .Values.adminToken }}
            checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
            {{- end }}
    ```

    **Почему так.** Kubernetes перезапускает поды, только когда меняется `spec.template`. Сама смена ConfigMap или Secret шаблон пода не трогает. Хеш содержимого в аннотации пода делает изменение видимым: другой хеш → другой template → rolling update. `if` нужен, потому что без `adminToken` файл `secret.yaml` рендерится пустым.

---

## Задача 8. Разнести поды по нодам: topologySpreadConstraints

**Цель.** У тебя два worker'а в kind. Сделай так, чтобы реплики по возможности распределялись по разным нодам.

```yaml
topologySpread:
  enabled: true
  maxSkew: 1
  whenUnsatisfiable: ScheduleAnyway
```

**Подсказка.** Уровень пода. В `labelSelector` нужны метки **твоих** подов — откуда их взять, чтобы не писать руками? Можно ли положить их прямо в values?

**Проверка.**

```bash
helm template app charts/app --show-only templates/deployment.yaml | yq '.spec.template.spec.topologySpreadConstraints'
# в кластере:
kubectl get pods -n app -o wide          # колонка NODE — поды на разных worker'ах
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    topologySpread:
      enabled: true
      maxSkew: 1
      whenUnsatisfiable: ScheduleAnyway
    ```

    `deployment.yaml`, уровень пода (отступ 6):

    ```yaml
          {{- if .Values.topologySpread.enabled }}
          topologySpreadConstraints:
            - maxSkew: {{ .Values.topologySpread.maxSkew }}
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
              labelSelector:
                matchLabels:
                  {{- include "app.selectorLabels" . | nindent 14 }}
          {{- end }}
    ```

    **Почему так.** Метки подов зависят от имени релиза (`app.kubernetes.io/instance: {{ .Release.Name }}`), а **values.yaml — не шаблон**: `{{ }}` внутри values не вычисляются. Поэтому весь блок пишется в шаблоне, а `labelSelector` берётся из того же хелпера, что и `selector` Deployment — совпадение гарантировано. `ScheduleAnyway` — «по возможности»: если вторая нода недоступна, поды всё равно запустятся (`DoNotSchedule` оставил бы их в `Pending`).

---

## Задача 9. Sidecar-контейнер

**Цель.** Дать возможность через values добавить в под дополнительные контейнеры:

```yaml
extraContainers:
  - name: sidecar
    image: busybox:1.36
    command: ["sh", "-c", "sleep infinity"]
```

**Подсказка.** Это **элементы списка** `containers`, на одном уровне с `- name: app`. Где кончается твой контейнер в `deployment.yaml`?

**Проверка.**

```bash
helm template app charts/app \
  --set 'extraContainers[0].name=sidecar' --set 'extraContainers[0].image=busybox:1.36' \
  --set 'extraContainers[0].command={sh,-c,sleep infinity}' \
  --show-only templates/deployment.yaml | yq '.spec.template.spec.containers[].name'
# в кластере:
kubectl get pod -n app -l app.kubernetes.io/name=app -o jsonpath='{.items[0].spec.containers[*].name}'
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    extraContainers: []
    ```

    `deployment.yaml` — в самом конце, после всех полей контейнера `app`:

    ```yaml
              {{- with .Values.resources }}
              resources:
                {{- toYaml . | nindent 12 }}
              {{- end }}
            {{- with .Values.extraContainers }}
            {{- toYaml . | nindent 8 }}
            {{- end }}
    ```

    **Почему так.** `- name: app` начинается с отступа 8 — элементы `extraContainers` должны начинаться там же, иначе они станут полями контейнера `app`. Учти: у sidecar нет `securityContext` из values. С `runAsNonRoot` на уровне пода busybox запустится от uid 10001, но если в кластере есть политика, требующая `readOnlyRootFilesystem` и `drop: [ALL]` у каждого контейнера, их нужно указать и в `extraContainers`.

---

## Задача 10. ServiceMonitor для слоя 4

**Цель.** Добавить шаблон `templates/servicemonitor.yaml` для Prometheus Operator:

* включается флагом `serviceMonitor.enabled`;
* **не ломает** установку, если в кластере ещё нет CRD Prometheus Operator;
* собирает `/metrics` с порта Service по **имени**.

**Подсказка.** ServiceMonitor ищет **Service** (не поды) по меткам. Наличие CRD проверяется через `.Capabilities.APIVersions.Has`. Посмотри «Карту 2».

**Проверка.**

```bash
helm template app charts/app --set serviceMonitor.enabled=true | grep -c "kind: ServiceMonitor"   # 0 — CRD нет
helm template app charts/app --set serviceMonitor.enabled=true \
  --api-versions monitoring.coreos.com/v1 --show-only templates/servicemonitor.yaml              # теперь есть
```

??? success "Решение"

    `values.yaml`:

    ```yaml
    serviceMonitor:
      enabled: false
      interval: 30s
      labels: {}          # например, release: kps — чтобы kube-prometheus-stack его подхватил
    ```

    `templates/servicemonitor.yaml`:

    ```yaml
    {{- if and .Values.serviceMonitor.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") }}
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: {{ include "app.fullname" . }}
      labels:
        {{- include "app.labels" . | nindent 4 }}
        {{- with .Values.serviceMonitor.labels }}
        {{- toYaml . | nindent 4 }}
        {{- end }}
    spec:
      selector:
        matchLabels:
          {{- include "app.selectorLabels" . | nindent 6 }}
      endpoints:
        - port: http
          path: /metrics
          interval: {{ .Values.serviceMonitor.interval }}
    {{- end }}
    ```

    **Почему так.** Три связи из карты: `selector` совпадает с метками **Service** — у Service стоят `app.labels`, а они включают `selectorLabels`. `port: http` — **имя** порта Service, не номер (поэтому у тебя в `service.yaml` порт назван `http`). `serviceMonitor.labels` нужны, потому что Prometheus из kube-prometheus-stack по умолчанию берёт только ServiceMonitor-ы с меткой своего релиза. Проверка `Capabilities` защищает от ошибки `no matches for kind "ServiceMonitor"`, если оператор ещё не установлен. При `helm template` без кластера CRD «нет», поэтому для проверки — `--api-versions`.

---

## Задача 11. values.schema.json — пусть Helm сам ловит ошибки

**Цель.** Добавить схему, чтобы `helm lint`, `helm template` и `helm install` падали на неправильных values: `replicaCount` не число, неизвестный `pullPolicy`, пустой `image.repository`, значения `config` не строки.

**Подсказка.** Файл `charts/app/values.schema.json` рядом с `values.yaml`, формат JSON Schema.

**Проверка.**

```bash
helm lint charts/app                                       # должен пройти
helm template app charts/app --set replicaCount=abc        # должен упасть
helm template app charts/app --set image.pullPolicy=Sometimes
helm template app charts/app --set config.READY_DELAY_SECONDS=3   # число, а не строка
```

??? success "Решение"

    ```json
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "type": "object",
      "required": ["image", "service", "resources"],
      "properties": {
        "replicaCount": { "type": "integer", "minimum": 1 },
        "image": {
          "type": "object",
          "required": ["repository"],
          "properties": {
            "repository": { "type": "string", "minLength": 1 },
            "tag": { "type": "string" },
            "pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] }
          }
        },
        "containerPort": { "type": "integer", "minimum": 1, "maximum": 65535 },
        "service": {
          "type": "object",
          "properties": {
            "type": { "enum": ["ClusterIP", "NodePort", "LoadBalancer"] },
            "port": { "type": "integer" }
          }
        },
        "resources": {
          "type": "object",
          "required": ["requests"],
          "properties": {
            "requests": { "type": "object", "required": ["cpu", "memory"] }
          }
        },
        "autoscaling": {
          "type": "object",
          "properties": {
            "enabled": { "type": "boolean" },
            "minReplicas": { "type": "integer", "minimum": 1 },
            "maxReplicas": { "type": "integer", "minimum": 1 }
          }
        },
        "config": {
          "type": "object",
          "additionalProperties": { "type": "string" }
        }
      }
    }
    ```

    Ошибка выглядит так:

    ```
    - at '/replicaCount': got string, want integer
    ```

    **Почему так.** Без схемы опечатка в values молча превращается в неправильный манифест (или в ошибку API-сервера при установке, далеко от места опечатки). Схема — документация и проверка в одном файле: читая её, видно, какие ключи у чарта есть и какого они типа. `config` со строковыми значениями ловит ровно ту проблему, из-за которой в шаблоне стоит `quote`. Учти: `--set config.X=3` передаёт **число** — для строки нужен `--set-string config.X=3`.

---

## Задача 12. Найди ошибку

Каждый фрагмент сломан. Найди проблему **до** того, как открыть ответ. Все сообщения об ошибках — настоящие, полученные на твоём чарте.

### 12.1

```yaml
          resources: {{ toYaml .Values.resources }}
```

```
Error: YAML parse error on app/templates/deployment.yaml: error converting YAML to JSON:
yaml: line 89: mapping values are not allowed in this context
```

??? success "Ответ"

    `toYaml` выдаёт многострочный текст, а он вставлен в ту же строку, что `resources:`, без переноса и отступа. Получается `resources: limits:` в одной строке — невалидный YAML. Правильно:

    ```yaml
              {{- with .Values.resources }}
              resources:
                {{- toYaml . | nindent 12 }}
              {{- end }}
    ```

    Найти строку: `helm template app charts/app --debug` выведет отрендеренный (невалидный) YAML — номер строки из ошибки указывает туда.

### 12.2

```yaml
          resources:
            {{- toYaml . | nindent 10 }}
```

`helm template` проходит без ошибок, но:

```
          resources:
          limits:
            cpu: 500m
          requests:
            cpu: 100m
```

??? success "Ответ"

    `nindent 10` вместо `12`: `limits` и `requests` встали на один уровень с `resources`, то есть стали полями **контейнера**, а `resources` — пустым. YAML валидный, поэтому Helm молчит. Kubernetes при установке отклонит манифест примерно так: `strict decoding error: unknown field "spec.template.spec.containers[0].limits"`. Правило: **N = отступ ключа + 2** (ключ `resources:` на 10 → `nindent 12`). Ловится `kubectl apply --dry-run=server` или `kubeconform -strict`.

### 12.3

```yaml
  {{- with .Values.ingress }}
  ingressClassName: {{ .className }}
  # и ниже, в том же with:
                  number: {{ .Values.service.port }}
  {{- end }}
```

```
Error: app/templates/ingress.yaml:14:47
  executing "app/templates/ingress.yaml" at <.Values.service.port>:
    nil pointer evaluating interface {}.service
```

??? success "Ответ"

    Внутри `with .Values.ingress` точка `.` — это уже `.Values.ingress`. `.Values.service` ищется как `.Values.ingress.Values.service` → nil. К корню — через `$`:

    ```yaml
                      number: {{ $.Values.service.port }}
    ```

    Так и сделано в твоём `ingress.yaml` внутри `range`: `include "app.fullname" $` и `$.Values.service.port`.

### 12.4

```yaml
# values.yaml
featureFlag: "on"
# deployment.yaml
            - name: FEATURE_FLAG
              value: {{ .Values.featureFlag }}
```

Рендер:

```yaml
            - name: FEATURE_FLAG
              value: on
```

??? success "Ответ"

    В values `"on"` — строка, но шаблон вывел её **без кавычек**. В итоговом YAML `on` читается как булево `true`, а `env[].value` бывает только строкой: при установке будет ошибка вида `cannot unmarshal bool into Go struct field EnvVar...value of type string`. Решение — `{{ .Values.featureFlag | quote }}`. Та же история с `yes`, `no`, `true`, `1.10`, `0123`.

### 12.5

```yaml
# service.yaml
      targetPort: web
```

`helm lint` и `helm template` — без ошибок. После деплоя `curl http://localhost/` → `503 Service Temporarily Unavailable`.

??? success "Ответ"

    Порт в контейнере называется `http`, а Service ищет порт с именем `web`. Такого нет — поды не попадают в endpoints, Ingress некуда отправлять запросы → 503. Helm связи между объектами не проверяет. Диагностика:

    ```bash
    kubectl get endpoints app -n app          # ENDPOINTS: <none>
    kubectl describe svc app -n app           # TargetPort: web/TCP, Endpoints: пусто
    kubectl get pod -n app -l app.kubernetes.io/name=app -o jsonpath='{.items[0].spec.containers[0].ports}'
    ```

    Правило: имя порта задаётся один раз в контейнере (`name: http`), а все остальные (Service `targetPort`, пробы, ServiceMonitor) ссылаются на это имя.

---

## Итог: чек-лист

Когда задачи сделаны, ты должен уметь без подсказок:

- [ ] по `kubectl explain` определить уровень любого поля;
- [ ] объяснить, почему `volumes` и `volumeMounts`, два `securityContext` и три места с `labels` стоят там, где стоят;
- [ ] пройти путь значения: values → строка шаблона → поле в итоговом манифесте;
- [ ] посчитать `nindent` для любого места;
- [ ] понимать, когда нужен `with`, `if`, `range`, `$`, `quote`, `include`;
- [ ] предсказать результат слияния `values.yaml` + `values-prod.yaml` + `--set`;
- [ ] проверить связи Service ↔ поды ↔ Ingress ↔ ServiceMonitor, когда Helm молчит;
- [ ] найти ошибку по сообщению `helm template` или по пустым endpoints.

Когда закончишь — закоммить ветку `helm-practice` и попроси меня сделать ревью: посмотрю, что получилось, и предложу следующие задачи (initContainer с ожиданием зависимостей, HTTPRoute из [Gateway API](gateway-api.md) вместо Ingress, библиотечный чарт с общими хелперами).
