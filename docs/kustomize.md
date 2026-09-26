# Kustomize

> Альтернатива — [Helm](helm.md). Используется вместе с [GitOps / Argo CD](gitops.md).

**Kustomize** — способ собрать манифесты Kubernetes для разных окружений **без шаблонов**. Берём обычные YAML (**base**) и накладываем поверх отличия для dev/prod (**overlays**). Встроен в `kubectl`: `kubectl apply -k`.

## Kustomize vs Helm

| | Kustomize | Helm |
|---|---|---|
| Подход | патчи поверх обычного YAML | шаблоны Go (`{{ .Values.x }}`) + values |
| Манифесты | валидный YAML, читается как есть | шаблоны, без рендера не прочитать |
| Логика (if, циклы) | нет | есть |
| Упаковка и версии | нет — просто папки в git | чарты с версиями, репозитории |
| Релизы и откат | нет (это делает GitOps/CI) | `helm history`, `helm rollback` |
| Установка | встроен в `kubectl` | отдельный бинарник |
| Лучше для | своих сервисов с отличиями по окружениям | переиспользуемых пакетов, чужого софта (Redis, Prometheus) |

> На практике часто вместе: сторонний софт — Helm-чартом, свои сервисы — Kustomize. Kustomize умеет и дорендерить Helm-чарт (`helmCharts:`).

## Структура

```
shop/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        ├── resources-patch.yaml
        └── config.env
```

## base

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
labels:
  - pairs:
      team: shop            # добавится всем ресурсам (без селекторов)
```

```yaml
# base/deployment.yaml — обычный манифест, без шаблонов
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: shop
  template:
    metadata:
      labels:
        app: shop
    spec:
      containers:
        - name: shop
          image: registry.example.com/shop:latest
          ports:
            - containerPort: 8080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
```

## overlays

```yaml
# overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop-dev
resources:
  - ../../base
nameSuffix: -dev
images:
  - name: registry.example.com/shop
    newTag: a1b2c3d
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop-prod
resources:
  - ../../base
images:
  - name: registry.example.com/shop
    newTag: "1.4.2"
replicas:
  - name: shop
    count: 3
patches:
  - path: resources-patch.yaml
configMapGenerator:
  - name: shop-config
    envs:
      - config.env
```

```yaml
# overlays/prod/resources-patch.yaml — strategic merge: указываем только то, что меняем
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  template:
    spec:
      containers:
        - name: shop
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits:   { memory: 1Gi }
```

## Основные возможности kustomization.yaml

| Поле | Что делает |
|---|---|
| `resources` | какие файлы / папки / другие kustomization включить |
| `namespace` | проставить namespace всем ресурсам |
| `namePrefix` / `nameSuffix` | добавить приставку к именам |
| `labels` / `commonAnnotations` | метки и аннотации на всё |
| `images` | подменить образ/тег без правки манифеста |
| `replicas` | число реплик |
| `patches` | патчи: strategic merge (кусок YAML) или JSON 6902 |
| `configMapGenerator` / `secretGenerator` | создать ConfigMap/Secret из файлов или `.env` |
| `components` | переиспользуемые куски для нескольких overlay-ев |

### JSON-патч — точечное изменение

```yaml
patches:
  - target:
      kind: Deployment
      name: shop
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: { name: LOG_LEVEL, value: debug }
```

### configMapGenerator и хеш в имени

```yaml
configMapGenerator:
  - name: shop-config
    literals:
      - LOG_LEVEL=info
```

Kustomize создаст ConfigMap `shop-config-5f7h8k9m2t` с хешем содержимого и поменяет ссылки на него в Deployment. **Поменял конфиг → поменялось имя → поды перезапустятся** автоматически. С обычным ConfigMap пришлось бы делать `rollout restart`.

## Команды

```bash
kubectl kustomize overlays/prod          # отрендерить итоговый YAML (посмотреть)
kubectl apply -k overlays/prod           # применить
kubectl diff -k overlays/prod            # что изменится в кластере
kubectl delete -k overlays/dev

# отдельный бинарник (новее, чем встроенный в kubectl)
kustomize build overlays/prod
cd overlays/dev && kustomize edit set image registry.example.com/shop=registry.example.com/shop:abc123
```

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Патч «не применился» | в патче не совпали `kind`/`metadata.name` с base | имя в патче — как в base (до `namePrefix`) |
| Контейнер в патче добавился вторым, а не изменился | не совпало `name` контейнера | `containers[].name` как в base |
| `accumulating resources: ... must be a directory or file` | неверный относительный путь в `resources` | пути от папки kustomization.yaml |
| Изменил ConfigMap — поды не перезапустились | ConfigMap без генератора | `configMapGenerator` (имя с хешем) |
| `kubectl apply -k` ведёт себя иначе, чем `kustomize build` | во встроенном kubectl старая версия Kustomize | использовать одну версию, в CI — отдельный бинарник |

## Best Practices

* **base — рабочий минимум**, overlays — только отличия.
* **Тег образа — через `images:`**, а не `sed` по манифесту.
* **`configMapGenerator`** для конфигов — автоматический перезапуск при изменении.
* **Перед мержем — `kubectl diff -k`** или `kustomize build` в CI.
* **Не строй глубокие цепочки overlay-ев** (overlay на overlay на overlay) — через год никто не поймёт итог.
