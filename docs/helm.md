# Helm

**Helm** — пакетный менеджер для Kubernetes. Вместо набора отдельных YAML-манифестов, скопированных под каждое окружение, приложение описывается **одним чартом** с шаблонами, а различия между окружениями выносятся в **values-файлы**.

`чарт (chart)` — пакет приложения: шаблоны манифестов + значения по умолчанию + метаданные.

`шаблон (template)` — манифест Kubernetes с подстановками `{{ ... }}` вместо захардкоженных значений.

`values` — значения, которые подставляются в шаблоны (образ, число реплик, лимиты, домен).

`релиз (release)` — установленный в кластер экземпляр чарта с конкретными values и своим именем.

`ревизия (revision)` — версия релиза; каждый `install`/`upgrade` создаёт новую, к любой можно откатиться.

## Проблема, которую решает Helm

Без Helm конфигурация размножается копированием: `deployment-dev.yaml`, `deployment-stage.yaml`, `deployment-prod.yaml` — три почти одинаковых файла, отличающихся числом реплик, тегом образа и лимитами.

| Проблема | Что происходит без Helm | Что даёт Helm |
|---|---|---|
| Дублирование YAML | Три копии манифеста на три окружения | Один шаблон + три values-файла |
| Рассинхрон окружений | Поправили в prod, забыли в stage | Правка в одном шаблоне применяется ко всем |
| Подстановка версии образа в CI | `sed`/`envsubst` по YAML | `--set image.tag=$CI_COMMIT_SHA` |
| Откат | Вручную искать предыдущий манифест | `helm rollback` по номеру ревизии |
| Установка чужого приложения | Собирать манифесты вручную | `helm install` из публичного репозитория |

> Ключевая идея: **шаблон описывает форму, values описывают содержание**. Один чарт покрывает все окружения, потому что различия вынесены наружу.

## Структура чарта

```
my-app/
├── Chart.yaml           # метаданные: имя, версия чарта, версия приложения
├── values.yaml          # значения по умолчанию
├── values-dev.yaml      # переопределения для dev (необязательное соглашение)
├── values-prod.yaml     # переопределения для prod
├── charts/              # зависимости (вложенные чарты)
├── .helmignore          # что не паковать в чарт (аналог .dockerignore)
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── configmap.yaml
    ├── _helpers.tpl     # именованные шаблоны (переиспользуемые куски)
    └── NOTES.txt        # текст, который выводится после install
```

### Chart.yaml

```yaml
apiVersion: v2
name: my-app
description: Сервис заказов
type: application
version: 0.2.0          # версия САМОГО ЧАРТА (меняется при правке шаблонов)
appVersion: "1.8.3"     # версия ПРИЛОЖЕНИЯ внутри (тег образа)
```

> Две версии путают чаще всего: `version` — про чарт (изменили шаблон → подняли), `appVersion` — про приложение (выкатили новый билд → подняли). Они живут независимо.

## Шаблонизация

### Основные объекты

| Объект | Что содержит | Пример |
|---|---|---|
| `.Values` | значения из values.yaml и `--set` | `{{ .Values.replicaCount }}` |
| `.Release` | информация о релизе | `{{ .Release.Name }}`, `{{ .Release.Namespace }}`, `{{ .Release.Revision }}` |
| `.Chart` | данные из Chart.yaml | `{{ .Chart.Name }}`, `{{ .Chart.AppVersion }}` |
| `.Capabilities` | возможности кластера | `{{ .Capabilities.KubeVersion }}` |
| `.Files` | файлы внутри чарта | `{{ .Files.Get "config.json" }}` |

### Пример шаблона

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-{{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          # default подставит appVersion, если tag не задан явно
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          ports:
            - containerPort: {{ .Values.service.port }}
          env:
            - name: LOG_LEVEL
              value: {{ .Values.logLevel | quote }}     # quote добавит кавычки
          resources:
            {{- toYaml .Values.resources | nindent 12 }} # вставить целый блок YAML с отступом
```

### Условия и циклы

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
# ...
{{- end }}

# перебор списка
env:
{{- range .Values.extraEnv }}
  - name: {{ .name }}
    value: {{ .value | quote }}
{{- end }}
```

> `{{-` и `-}}` съедают пробелы и перевод строки — без них в отрендеренном YAML остаются пустые строки и ломается отступ. Ошибки отступа в Helm ловятся именно через `helm template`.

### Полезные функции

| Функция | Что делает |
|---|---|
| `default "значение"` | подставить значение, если переменная пустая |
| `quote` | обернуть в кавычки (важно для чисел-строк, например `"8080"`) |
| `nindent N` | перевод строки + отступ N пробелов |
| `toYaml` | превратить структуру values в YAML-блок |
| `required "сообщение" .Values.x` | упасть с понятной ошибкой, если значение не задано |
| `include "имя" .` | вставить именованный шаблон из `_helpers.tpl` |

### Именованные шаблоны (_helpers.tpl)

```yaml
{{- define "my-app.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end }}
```

Использование: `name: {{ include "my-app.fullname" . }}` — имя формируется в одном месте, а не копируется по всем манифестам.

## Values и окружения

### values.yaml (значения по умолчанию)

```yaml
replicaCount: 1

image:
  repository: registry.example.com/my-app
  tag: ""          # пусто → возьмётся appVersion из Chart.yaml
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 8000

logLevel: info

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

ingress:
  enabled: false
```

### values-prod.yaml (только отличия)

```yaml
replicaCount: 4

logLevel: warn

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi

ingress:
  enabled: true
  host: api.example.com
```

> В values для окружения держат **только различия**, а не полную копию — иначе возвращается та же проблема дублирования, ради которой брали Helm.

### Приоритет значений (от низшего к высшему)

```
values.yaml чарта
  ↓ перекрывается
-f values-prod.yaml         (несколько -f применяются слева направо)
  ↓ перекрывается
--set key=value             (самый высокий приоритет)
```

```bash
helm upgrade --install my-app ./my-app \
  -f values-prod.yaml \
  --set image.tag=1.8.4        # перекроет и values.yaml, и values-prod.yaml
```

## Жизненный цикл релиза

Каждый `install`/`upgrade` создаёт **новую ревизию**. Helm хранит историю релиза в кластере (в Secret в том же namespace) — поэтому откат не требует ни git, ни сохранённых локально манифестов.

```bash
helm install my-app ./my-app                 # ревизия 1
helm upgrade my-app ./my-app --set image.tag=1.8.4   # ревизия 2
helm upgrade my-app ./my-app --set replicaCount=6    # ревизия 3
helm rollback my-app 2                        # откат к ревизии 2 → создаёт ревизию 4
```

> Откат не «удаляет» ревизию 3 — он создаёт **новую** ревизию с содержимым второй. История линейна и ничего не теряется.

```bash
helm history my-app
```
```
REVISION  UPDATED       STATUS      CHART        APP VERSION  DESCRIPTION
1         Mon Sep 14..  superseded  my-app-0.2.0 1.8.3        Install complete
2         Mon Sep 14..  superseded  my-app-0.2.0 1.8.4        Upgrade complete
3         Mon Sep 14..  superseded  my-app-0.2.0 1.8.4        Upgrade complete
4         Mon Sep 14..  deployed    my-app-0.2.0 1.8.4        Rollback to 2
```

### Безопасный деплой

```bash
helm upgrade --install my-app ./my-app \
  -f values-prod.yaml \
  --set image.tag=$CI_COMMIT_SHA \
  --namespace production --create-namespace \
  --wait --timeout 5m --atomic
```

| Флаг | Что делает | Зачем |
|---|---|---|
| `--install` | установить, если релиза ещё нет | одна команда и для первого деплоя, и для обновления — удобно в CI |
| `--wait` | ждать, пока поды станут Ready | без него команда завершается успехом сразу после отправки манифестов |
| `--timeout 5m` | максимум ожидания | чтобы пайплайн не висел вечно |
| `--atomic` | при неудаче автоматически откатить релиз | кластер не остаётся в полусломанном состоянии |
| `--create-namespace` | создать namespace, если его нет | первый деплой в новое окружение |

> `--atomic` включает `--wait` автоматически. Связка `--wait --timeout --atomic` — это «деплой либо полностью успешен, либо откачен»: ровно то поведение, которое нужно в CD (см. [CD](cd.md)).

## Проверка до применения

```bash
helm lint ./my-app                         # структура чарта и типовые ошибки
helm template my-app ./my-app -f values-prod.yaml   # отрендерить YAML локально, БЕЗ кластера
helm upgrade --install my-app ./my-app --dry-run --debug  # рендер + проверка на API-сервере
```

| Команда | Нужен кластер? | Что проверяет |
|---|---|---|
| `helm lint` | нет | структуру чарта, синтаксис шаблонов |
| `helm template` | нет | что именно получится в итоговых манифестах |
| `--dry-run --debug` | да | дополнительно валидацию манифестов API-сервером |

> `helm template` — главный инструмент отладки: почти все проблемы (отступы, пустые значения, неверный тип) видны в отрендеренном YAML ещё до похода в кластер.

## Просмотр установленного релиза

```bash
helm list                        # релизы в текущем namespace
helm list -A                     # во всех namespace
helm status my-app               # состояние релиза и NOTES.txt
helm get values my-app           # какие values реально применены
helm get values my-app --all     # включая значения по умолчанию
helm get manifest my-app         # какие манифесты Helm применил в кластер
helm uninstall my-app            # удалить релиз и все его ресурсы
```

> `helm get values` + `helm get manifest` — то, чем разбирают инцидент «в кластере не то, что ожидали»: сначала смотрят, с какими values релиз собран, потом — что из них отрендерилось.

## Helm в CI/CD

Типовая схема: пайплайн собрал образ с уникальным тегом и передаёт этот тег Helm'у, всё остальное описано в чарте.

```yaml
# .gitlab-ci.yml
deploy:
  stage: deploy
  script:
    - helm lint ./charts/my-app
    - helm upgrade --install my-app ./charts/my-app
        --namespace production --create-namespace
        -f ./charts/my-app/values-prod.yaml
        --set image.tag=$CI_COMMIT_SHA
        --wait --timeout 5m --atomic
  environment:
    name: production
  only:
    - main
```

* **Immutable-тег образа** (`$CI_COMMIT_SHA`, а не `latest`) — обязателен: только так понятно, какая версия сейчас в кластере, и только так работает откат (см. [CD](cd.md)).
* **Секреты не кладут в values-файлы в git** — они приходят из защищённых переменных CI (`--set`) или из внешнего секрет-менеджера (см. [Безопасность](security.md)).
* **`--atomic` в пайплайне** заменяет ручной откат: неуспешный деплой сам возвращает предыдущее состояние.

## Зависимости и репозитории чартов

Чарт может подключать другие чарты как зависимости (например, приложение + redis):

```yaml
# Chart.yaml
dependencies:
  - name: redis
    version: "18.19.2"
    repository: "https://charts.bitnami.com/bitnami"
    condition: redis.enabled      # ставить, только если redis.enabled=true
```

```bash
helm dependency update ./my-app       # скачать зависимости в charts/
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo redis                 # найти чарт в подключённых репозиториях
helm install my-redis bitnami/redis    # установить готовый чужой чарт
```

> Готовые чарты — вторая сильная сторона Helm: Prometheus, Grafana, ingress-nginx, cert-manager обычно ставят именно так, а не собирая десятки манифестов руками (см. [Мониторинг](monitoring.md)).

## Helm vs kubectl apply vs Kustomize

| | `kubectl apply` | Kustomize | Helm |
|---|---|---|---|
| Подход | голые YAML | наложение патчей на базовые YAML | шаблонизация + пакет |
| Окружения | копии файлов | overlays (base + патчи) | values-файлы |
| Логика (if/range) | нет | нет | есть |
| История и откат | только через `kubectl rollout undo` (на уровне Deployment) | нет своей | ревизии релиза целиком |
| Готовые пакеты | нет | нет | публичные репозитории чартов |
| Сложность | минимальная | средняя | выше, легко «перешаблонить» |

> Kustomize хорош, когда различия окружений — это пара патчей. Helm выигрывает, когда нужны условная логика, переиспользование чарта между командами, установка стороннего софта и откат релиза как единого целого.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `helm upgrade` прошёл успешно, но приложение не работает | Без `--wait` команда не ждёт готовности подов | `--wait --timeout 5m --atomic` |
| Ошибка «error converting YAML» при рендере | Сломан отступ после `toYaml` или `range` | `helm template` и `nindent` вместо `indent` |
| Значение `8080` стало числом, а manifest требует строку | Нет `quote` | `{{ .Values.port | quote }}` |
| Релиз завис в статусе `pending-upgrade` | Предыдущий upgrade прервали (Ctrl+C, таймаут CI) | `helm rollback <release> <последняя рабочая ревизия>` |
| `--set` не применился | Путь к ключу не совпадает с values.yaml | `helm get values <release>` и проверить структуру |
| В values-prod продублирован весь values.yaml | Скопировали файл целиком | Оставить только отличия |
| Секрет виден в `helm get values` | Секрет передан через values/`--set` и сохранён в истории релиза | Держать секреты в K8s Secret/Vault, ссылаться из шаблона |

## Best Practices

* **Шаблон один, values много** — различия окружений живут только в values-файлах.
* **`helm lint` + `helm template` в CI до деплоя** — дешёвая проверка, ловит большинство ошибок без кластера.
* **`--atomic --wait --timeout` для любого автоматического деплоя** — либо успех, либо откат, без промежуточных состояний.
* **Immutable-теги образов** (`$CI_COMMIT_SHA`), никогда `latest` — иначе `rollback` возвращает тот же самый образ.
* **Версионируй чарт** (`version` в Chart.yaml) при каждом изменении шаблонов.
* **`required` для критичных значений** — лучше упасть при рендере с понятным сообщением, чем задеплоить пустое поле.
* **Не храни секреты в values в git** — только CI-переменные или внешний секрет-менеджер.

> Мини-шпаргалка: [Helm: шпаргалка команд](helm-cheatsheet.md).
> Объекты Kubernetes, которые Helm разворачивает: [Kubernetes (теория)](k8s.md).
