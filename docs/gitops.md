# GitOps и Argo CD

> Шпаргалка — [Argo CD: шпаргалка](argocd-cheatsheet.md). Стратегии выкатки — [CD: стратегии](cd-strategies.md). Что деплоим — [Helm](helm.md), [Kustomize](kustomize.md).

**GitOps** — подход к деплою, при котором **git-репозиторий — единственный источник правды** о том, что должно быть запущено. Никто не делает `kubectl apply` руками: ты меняешь YAML в git, а агент в кластере сам приводит кластер в соответствие.

## Четыре принципа GitOps (OpenGitOps)

| Принцип | Что значит |
|---|---|
| **Декларативность** | описываем желаемое состояние («3 реплики образа v1.2»), а не шаги |
| **Версионирование** | состояние хранится в git: история, ревью, откат через `git revert` |
| **Pull, а не push** | агент в кластере сам забирает изменения из git |
| **Постоянная сверка** | агент всё время сравнивает кластер с git и исправляет расхождения (drift) |

## Push vs Pull деплой

**Push (классический CI/CD):**

```
git push → CI собирает образ → CI делает helm upgrade / kubectl apply → кластер
```

**Pull (GitOps):**

```
git push (код)    → CI собирает образ → CI меняет тег в репо конфигурации
git (конфигурация) ← Argo CD в кластере следит → применяет изменения в кластер
```

| | Push | Pull (GitOps) |
|---|---|---|
| У кого доступ к кластеру | у CI (credentials снаружи) | только у агента внутри кластера |
| Ручные правки в кластере | живут, пока кто-то не заметит | автоматически откатываются к git |
| Что сейчас в проде | надо смотреть в кластер | написано в git |
| Откат | перезапуск старого пайплайна | `git revert` |
| Несколько кластеров | CI нужен доступ ко всем | в каждом свой агент |

## Инструменты

* **Argo CD** — самый популярный, с веб-интерфейсом, проект CNCF.
* **Flux** — тоже CNCF, без встроенного UI, «всё через CRD».

Дальше — про Argo CD.

## Установка Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# пароль admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# веб-интерфейс на https://localhost:8080
kubectl port-forward svc/argocd-server -n argocd 8080:443

# CLI
brew install argocd
argocd login localhost:8080 --username admin --insecure
```

Для прода — через Helm-чарт `argo/argo-cd` с values в git.

## Application — главный ресурс

`Application` связывает **источник** (git-репо + путь) и **назначение** (кластер + namespace):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shop-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/company/k8s-config.git
    targetRevision: main          # ветка, тег или коммит
    path: apps/shop/overlays/prod # где лежат манифесты
  destination:
    server: https://kubernetes.default.svc   # этот же кластер
    namespace: shop
  syncPolicy:
    automated:
      prune: true                 # удалять из кластера то, что удалили из git
      selfHeal: true              # откатывать ручные изменения в кластере
    syncOptions:
      - CreateNamespace=true
```

Источник может быть:

* обычными YAML-файлами;
* **Kustomize** (Argo CD сам вызовет `kustomize build`);
* **Helm-чартом** из git или Helm-репозитория:

```yaml
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: redis
    targetRevision: 19.6.0
    helm:
      valuesObject:
        architecture: standalone
```

## Статусы

| Статус | Значения | Что значит |
|---|---|---|
| **Sync** | `Synced` / `OutOfSync` | совпадает ли кластер с git |
| **Health** | `Healthy` / `Progressing` / `Degraded` / `Missing` | работает ли приложение (поды Ready, Deployment раскатан) |

`Synced` + `Degraded` — применили то, что в git, но оно не работает (например, образ не существует).

## Drift и selfHeal

**Drift** — расхождение кластера и git. Кто-то сделал `kubectl scale deploy shop --replicas=10`:

* без `selfHeal` — приложение станет `OutOfSync`, в UI будет видно, что поменялось;
* с `selfHeal: true` — Argo CD через несколько секунд вернёт 3 реплики из git.

> Если какое-то поле **должно** меняться в кластере (например, `replicas` управляет HPA) — его нужно исключить через `ignoreDifferences`, иначе Argo CD и HPA будут бесконечно спорить.

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

## Структура репозиториев

Обычно разделяют **два репозитория**:

| Репозиторий | Что в нём | Кто меняет |
|---|---|---|
| **app** (код) | исходники, Dockerfile, тесты | разработчики; CI собирает образ |
| **config** (манифесты) | Helm values / Kustomize overlays для окружений | CI (обновляет тег) и люди через merge request |

```
k8s-config/
├── apps/
│   ├── shop/
│   │   ├── base/                  # общие манифесты
│   │   └── overlays/
│   │       ├── dev/
│   │       ├── staging/
│   │       └── prod/
│   └── payments/
└── argocd/
    ├── root.yaml                  # app-of-apps
    └── apps/
        ├── shop-dev.yaml
        ├── shop-prod.yaml
        └── payments-prod.yaml
```

### Шаг CI: обновить тег в config-репо

```yaml
# .gitlab-ci.yml репозитория приложения
update-config:
  stage: deploy
  script:
    - git clone https://ci:${CONFIG_TOKEN}@gitlab.com/company/k8s-config.git
    - cd k8s-config/apps/shop/overlays/dev
    - kustomize edit set image shop=registry.example.com/shop:${CI_COMMIT_SHORT_SHA}
    - git commit -am "shop dev → ${CI_COMMIT_SHORT_SHA}"
    - git push
```

Дальше Argo CD сам увидит коммит и выкатит. Для прода — то же через merge request с ревью. Автоматизировать обновление тегов умеет **Argo CD Image Updater**.

## App of Apps и ApplicationSet

**App of Apps** — одно «корневое» Application, которое указывает на папку с другими Application. Добавил файл в `argocd/apps/` → появилось новое приложение.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/company/k8s-config.git
    targetRevision: main
    path: argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

**ApplicationSet** — генерирует много Application по шаблону: для каждой папки, каждого кластера, каждого окружения.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: shop
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
          - env: staging
          - env: prod
  template:
    metadata:
      name: 'shop-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/company/k8s-config.git
        targetRevision: main
        path: 'apps/shop/overlays/{{env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'shop-{{env}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```

## Порядок и хуки

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"     # применяется раньше волны 0 (например, миграции/CRD)
```

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync        # Job миграции БД перед обновлением
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

## Секреты в GitOps

Секреты **нельзя** класть в git открытым текстом. Варианты — Sealed Secrets, SOPS, External Secrets Operator. Подробно — [Секреты](secrets.md).

## Откат

```bash
git revert <коммит>   && git push     # правильный способ: git снова источник правды
argocd app history shop-prod
argocd app rollback shop-prod <id>     # быстрый откат, но при autosync его перезапишет git
```

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Приложение всегда `OutOfSync` | поле меняет контроллер (HPA, mutating webhook) | `ignoreDifferences` |
| Удалили манифест из git, ресурс остался | нет `prune: true` | включить `prune` (осознанно!) |
| Ручной фикс в кластере «пропал» | `selfHeal` вернул состояние из git | чинить через git |
| `Synced`, но `Degraded` | манифест применён, но под не стартует | `kubectl describe pod`, события, логи |
| `rollback` через UI откатился обратно | autosync снова применил HEAD из git | откатывать через `git revert` |
| `ComparisonError` | ошибка рендера Helm/Kustomize или нет доступа к репо | `argocd app get`, проверить репо и `helm template` / `kustomize build` локально |

## Best Practices

* **Раздельные репозитории** кода и конфигурации.
* **Никаких `kubectl apply` руками в прод** — только через git.
* **`selfHeal` + `prune`** для полноценного GitOps, `ignoreDifferences` для управляемых полей.
* **Прод — через merge request** с ревью, dev — автообновление тегов.
* **Пинни версии** Helm-чартов (`targetRevision`) и образов — не `latest`.
* **Argo CD сам под GitOps** — его настройки и Application тоже в git (app-of-apps).
