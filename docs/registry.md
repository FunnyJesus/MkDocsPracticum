# Container Registry

> Сборка образов — [Docker](docker.md). Сканирование и supply chain — [Безопасность](security.md).

**Container registry** — хранилище Docker-образов. CI собирает образ и делает `push`, Kubernetes/Docker на серверах делают `pull`. Это мост между «собрали» и «запустили».

## Путь образа: от кода до пода

В кластер **нельзя загрузить код или образ напрямую**. Кластер получает только **инструкцию** —
манифест со **ссылкой** на образ, а за самим образом узлы ходят в registry сами.

```
 CI: build                CD: deploy                     КЛАСТЕР
 ─────────                ──────────                     ───────
 docker build             helm upgrade / kubectl apply   kubelet на узле
 docker push  ──► REGISTRY ◄──────────────────────────── скачивает образ ПО ССЫЛКЕ
                     ▲    манифест: image: reg/app:1.4.2 ──► API кластера
                     └──── образ лежит здесь
```

Аналогия: **образ** — коробка на складе (registry), **манифест** — накладная «возьми со склада вот
эту коробку, сделай 2 экземпляра, проверяй так», **кластер** — курьер, который сам едет на склад.

| Шаг | Кто | Что нужно |
|---|---|---|
| упаковать приложение в образ и загрузить в registry | CI | право **push** |
| отправить в кластер манифест со ссылкой (`image: ...`) | CD (Helm, kubectl, Argo CD) | доступ к **API кластера**, образы ему не нужны |
| скачать образ и запустить контейнер | узел кластера (kubelet) | право **pull** |

Поэтому деплой — это не «загрузить образ в кластер», а «изменить ссылку в манифесте»:
`helm upgrade --set image.tag=1.4.3` → в Deployment новая ссылка → узлы скачивают новый образ.

**Исключение для локальных кластеров:** kind и minikube не видят образы Docker хоста, их загружают
прямо в узлы без registry: `kind load docker-image app:dev --name lab` (+ `imagePullPolicy: IfNotPresent`).

## Какие бывают

| Registry | Тип | Комментарий |
|---|---|---|
| **Docker Hub** | публичный SaaS | лимиты на анонимный pull — неприятный сюрприз в CI |
| **GitHub Container Registry** (`ghcr.io`) | SaaS | удобно для проектов на GitHub |
| **GitLab Container Registry** | SaaS / self-hosted | встроен в каждый проект GitLab |
| **AWS ECR**, **Google Artifact Registry**, **Azure ACR**, **Yandex Container Registry** | облачные | доступ через IAM облака |
| **Harbor** | self-hosted, CNCF | сканирование, подпись, репликация, квоты, RBAC |
| **Nexus**, **JFrog Artifactory** | self-hosted | хранят и образы, и пакеты (pip, npm, maven, helm) |
| `registry:2` / **Distribution** | self-hosted минимум | просто хранилище без UI |

## Адрес образа

```
registry.example.com:5000/team/shop:1.4.2
└────────── host ───────┘└ repo ┘└ tag ┘

nginx:1.27                   = docker.io/library/nginx:1.27
ghcr.io/company/shop@sha256:3f1a…   ← по digest (неизменяемая ссылка)
```

* **Тег** — метка, её можно перезаписать (`latest` сегодня и завтра — разные образы).
* **Digest** (`sha256:…`) — хеш содержимого, **не меняется никогда**.

## Работа с registry

```bash
docker login registry.example.com                       # логин (в CI — через токен)
echo "$CI_REGISTRY_PASSWORD" | docker login -u "$CI_REGISTRY_USER" --password-stdin "$CI_REGISTRY"

docker build -t registry.example.com/team/shop:1.4.2 .
docker push registry.example.com/team/shop:1.4.2
docker pull registry.example.com/team/shop:1.4.2

docker tag shop:local registry.example.com/team/shop:1.4.2   # переименовать локальный образ
docker inspect --format '{{index .RepoDigests 0}}' registry.example.com/team/shop:1.4.2   # узнать digest
```

Без Docker-демона (удобно в CI):

```bash
crane ls registry.example.com/team/shop                 # список тегов
crane digest registry.example.com/team/shop:1.4.2
crane copy src/shop:1.4.2 dst/shop:1.4.2                # скопировать между registry
skopeo inspect docker://registry.example.com/team/shop:1.4.2
```

## Стратегия тегов

| Тег | Пример | Когда |
|---|---|---|
| **SHA коммита** | `shop:a1b2c3d` | каждый билд в CI — однозначно связан с кодом |
| **SemVer** | `shop:1.4.2`, `shop:1.4`, `shop:1` | релизы |
| **Ветка** | `shop:main`, `shop:feature-login` | dev-стенды (перезаписывается) |
| `latest` | `shop:latest` | только локально, **не для деплоя** |

```bash
# в CI: один образ — несколько тегов
docker build -t $IMAGE:$CI_COMMIT_SHORT_SHA .
docker push $IMAGE:$CI_COMMIT_SHORT_SHA
if [ -n "$CI_COMMIT_TAG" ]; then
  docker tag $IMAGE:$CI_COMMIT_SHORT_SHA $IMAGE:$CI_COMMIT_TAG
  docker push $IMAGE:$CI_COMMIT_TAG
fi
```

> **Правило:** в прод деплоим **неизменяемый** тег (SHA/версия) или digest. Иначе `rollback` на «тот же» тег может поднять другой образ. Многие registry умеют **tag immutability** — запрет перезаписи тега.

## Доступ из Kubernetes

Приватный registry → нужен секрет с логином:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot-k8s \
  --docker-password="$TOKEN" \
  -n shop
```

```yaml
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: shop
      image: registry.example.com/team/shop:1.4.2
```

В облаках вместо секрета — IAM: нодам кластера (или сервис-аккаунту) выдаётся роль на чтение registry.

## Retention: очистка старых образов

Каждый коммит → новый образ по 200 МБ → через год терабайты. Нужны **правила очистки**:

* хранить последние N тегов на ветку;
* удалять теги старше X дней, кроме релизных (`v*`);
* никогда не удалять то, что сейчас задеплоено.

Настраивается в самом registry (GitLab: Cleanup policies, Harbor: Tag retention, ECR: Lifecycle policy). После удаления тегов в self-hosted registry нужен **garbage collection**, чтобы реально освободить диск.

## Pull-through cache и зеркала

* **Pull-through cache / proxy cache** — свой registry проксирует Docker Hub: быстрее, нет лимитов, работает при недоступности Docker Hub.
* **Зеркалирование** — копировать нужные публичные образы в свой registry и запускать только оттуда (контроль, что именно запускается).

```json
// /etc/docker/daemon.json
{ "registry-mirrors": ["https://mirror.example.com"] }
```

## Helm-чарты в registry (OCI)

Современные registry хранят не только образы, но и **Helm-чарты** — как OCI-артефакты. Один реестр
на всё, те же права и retention:

```bash
helm registry login registry.example.com -u robot-ci --password-stdin < token
helm package charts/shop --version 1.4.2 --app-version 1.4.2
helm push shop-1.4.2.tgz oci://registry.example.com/team/charts
helm upgrade --install shop oci://registry.example.com/team/charts/shop --version 1.4.2
```

Деплой из registry, а не из рабочей копии: в кластер попадает ровно та версия чарта, что выпущена
в релизе (так сделано в [дипломе](diploma-cicd.md)).

## Образы в values чарта — для подмены на зеркала

Все образы, которые использует чарт (в том числе служебные: curl для тестов, sidecar'ы), выноси в
`values.yaml`, а не зашивай в шаблоны:

```yaml
images:
  app: registry.example.com/team/shop:1.4.2
  tester: alpine/k8s:1.31.4          # в закрытом контуре → registry.company/mirror/alpine/k8s:1.31.4
  python: python:3.12-alpine
```

В закрытом контуре (корпоративная сеть без доступа в интернет) публичные образы берутся из зеркала
во внутреннем registry — и чарт ставится без правки шаблонов, одним values-файлом.

## Код без своего образа: ConfigMap

Для маленьких служебных инструментов (дашборд, агент проверок, скрипт) можно **не собирать свой
образ**: взять стандартный (`python:3.12-alpine`) и положить код в ConfigMap — так устроен дашборд
в проекте cluster-tests.

```yaml
kind: ConfigMap
metadata: { name: dashboard }
data:
  dashboard.py: |
    {{- .Files.Get "files/dashboard.py" | nindent 4 }}
---
# в Deployment:
      containers:
        - name: dashboard
          image: python:3.12-alpine                 # образ — по ссылке, как всегда
          command: ["python3", "/app/dashboard.py"]  # код — не из образа, а из ConfigMap
          volumeMounts: [{ name: app, mountPath: /app }]
      volumes:
        - name: app
          configMap: { name: dashboard }
```

| | Свой образ | Стандартный образ + ConfigMap |
|---|---|---|
| Сборка в CI и registry | нужны | не нужны |
| Обновление | новый образ + деплой | `helm upgrade` (+ аннотация `checksum/...` для перезапуска) |
| Зависимости (`pip`, `npm`) | любые | только то, что есть в образе (стандартная библиотека) |
| Размер кода | любой | ConfigMap ≤ 1 МиБ |
| Для чего | приложения | маленькие утилиты и скрипты |

## Корпоративный registry: что выяснить

В компании обычно свой registry (Harbor, Nexus, Artifactory, GitLab) внутри сети. Прежде чем
что-то пушить, спроси у DevOps/платформенной команды:

1. Есть ли у команды проект в registry и как получить доступ?
2. Пушат люди или только CI (robot-аккаунт)?
3. Правила имён и тегов (`registry/<команда>/<сервис>:<версия>`)?
4. Есть ли зеркало Docker Hub — откуда брать базовые образы?
5. Какие проверки (сканер, подпись) образ проходит перед деплоем?

Проверить доступ без риска: `docker login <registry>` и `docker pull` образа своей команды.
**Личные и учебные проекты в рабочий registry не пушить** — для них `ghcr.io` или Docker Hub.

## Безопасность образов

```bash
trivy image registry.example.com/team/shop:1.4.2        # уязвимости

# подпись образа (Sigstore cosign)
cosign sign registry.example.com/team/shop@sha256:3f1a…
cosign verify registry.example.com/team/shop@sha256:3f1a… \
  --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*'
```

* **Сканирование** — в CI перед push и периодически в registry (новые CVE находят в старых образах).
* **Подпись (cosign)** + политика в кластере (Kyverno, Sigstore policy-controller): запускать только подписанные образы.
* **Отдельные учётки**: CI — push, кластер — только pull (robot-аккаунты, deploy tokens).

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `ImagePullBackOff` / `ErrImagePull` | опечатка в имени/теге, нет `imagePullSecrets`, нет доступа | `kubectl describe pod` → Events; проверить `docker pull` с теми же данными |
| `toomanyrequests` от Docker Hub | лимит анонимных pull | логин, pull-through cache, свой registry |
| Откат не помог — «тот же» тег, другой образ | тег перезаписан | неизменяемые теги (SHA), digest, tag immutability |
| Диск registry переполнен | нет retention | cleanup policies + garbage collection |
| `http: server gave HTTP response to HTTPS client` | registry без TLS | включить TLS; для теста — `insecure-registries` в daemon.json |
| `no matching manifest for linux/arm64` | образ собран только под amd64 | `docker buildx build --platform linux/amd64,linux/arm64` |
| `ErrImagePull` в kind на локально собранный образ | kind не видит образы Docker хоста, а тег не из registry | `kind load docker-image <образ> --name <кластер>` и `imagePullPolicy: IfNotPresent` |

## Best Practices

* **Деплой по SHA-тегу или digest**, `latest` — никогда.
* **Retention-политики** с первого дня.
* **Свой registry / proxy cache** для базовых образов — не зависеть от Docker Hub.
* **Сканируй и подписывай** образы, в кластере пускай только из доверенного registry.
* **Минимальные права**: push только у CI, pull — у кластера.
