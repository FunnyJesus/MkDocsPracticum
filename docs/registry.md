# Container Registry

> Сборка образов — [Docker](docker.md). Сканирование и supply chain — [Безопасность](security.md).

**Container registry** — хранилище Docker-образов. CI собирает образ и делает `push`, Kubernetes/Docker на серверах делают `pull`. Это мост между «собрали» и «запустили».

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

## Best Practices

* **Деплой по SHA-тегу или digest**, `latest` — никогда.
* **Retention-политики** с первого дня.
* **Свой registry / proxy cache** для базовых образов — не зависеть от Docker Hub.
* **Сканируй и подписывай** образы, в кластере пускай только из доверенного registry.
* **Минимальные права**: push только у CI, pull — у кластера.
