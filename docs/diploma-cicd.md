# Диплом: CI/CD в GitLab

Конвейер Momo Store: от push в ветку до релиза в кластере.
Общий обзор — [на главной странице раздела](diploma-momo-store.md).

## Схема

```
 push в ветку / MR                         тег vX.Y.Z на master
 ────────────────                          ─────────────────────
 build   backend-build, frontend-build     build   (оба образа всегда)
         kaniko → :<sha>                   test    (всё)
 test    backend-lint                      release release-images  :<sha> → :X.Y.Z (crane)
         backend-unit-test                         release-chart   helm push OCI
         backend-image-scan (trivy)                release-notes   GitLab Release
         frontend-audit                    deploy  deploy-production
         frontend-image-scan (trivy)               helm --atomic + smoke-test
         dockerfile-lint (hadolint)        .post   notify-success / notify-failure (Telegram)
         helm-lint (+ kubeconform)
         terraform-validate
         sonarqube (если заданы SONAR_*)
```

## Структура

```yaml
# .gitlab-ci.yml
stages: [build, test, release, deploy]

workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS   # нет дубля branch-пайплайна при открытом MR
      when: never
    - if: $CI_COMMIT_BRANCH
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/

variables:
  REGISTRY: cr.yandex/${YC_REGISTRY_ID}
  BACKEND_IMAGE: ${REGISTRY}/momo-backend
  FRONTEND_IMAGE: ${REGISTRY}/momo-frontend
  CHART_REPO: oci://${REGISTRY}/charts
  SHA_TAG: ${CI_COMMIT_SHORT_SHA}     # 8 символов — под это правило очистки реестра
  K8S_IMAGE: alpine/k8s:1.34.5        # helm 3.19 + kubectl + kubeconform + git + curl + jq

include:
  - local: ci/templates.yml           # .kaniko-build, .trivy-scan, .hadolint
  - local: ci/backend.yml
  - local: ci/frontend.yml
  - local: ci/infra.yml               # dockerfile-lint, helm-lint, terraform-validate, sonarqube
  - local: ci/release.yml
  - local: ci/deploy.yml
  - local: ci/notify.yml
```

Один пайплайн с `include: local`, а не parent/child: стадии build → test → release → deploy
идут строго по порядку для всего продукта, и `needs` между компонентами проще.

### Запуск только при изменениях

```yaml
.backend-rules:
  rules:
    - if: $CI_COMMIT_TAG                 # на теге — всегда
    - changes: [backend/**/*, ci/backend.yml, ci/templates.yml]
```

!!! note "Как считается `changes`"
    * **Пайплайн ветки** — сравнение с предыдущим push в эту ветку. На втором push, где менялись только
      Dockerfile'ы, задачи `helm-lint` и `terraform-validate` не запустились — это нормально.
    * **Пайплайн MR** — сравнение с целевой веткой → запускается всё, что отличается от `master`.
    * **Новая ветка** — `changes` всегда true.
    * **Тег** — сравнивать не с чем, поэтому явное `if: $CI_COMMIT_TAG`.

## Переменные CI и флаги

| Переменная | Тип | Protected | Почему так |
|---|---|---|---|
| `YC_REGISTRY_ID` | Variable | **нет** | нужна build на **любой** ветке (push образов) |
| `YC_CI_KEY` | **File** | **нет** | ключ SA для push — тоже нужен на ветках |
| `KUBECONFIG` | **File** | **да** | деплой только с защищённого тега — ключ к кластеру не утечёт из feature-ветки |
| `APP_URL` | Variable | да | нужен только deploy (тег) |
| `IMAGES_BASE_URL` | Variable | да | нужен только deploy |
| `TELEGRAM_BOT_TOKEN` | Variable | — | Masked |
| `TELEGRAM_CHAT_ID` | Variable | — | |

!!! danger "Protected-переменные видны только защищённым веткам и тегам"
    Я сначала поставил Protected на `YC_REGISTRY_ID` — пайплайн ветки получил бы пустой адрес реестра
    (`cr.yandex/`) и упал на push. А для `KUBECONFIG` Protected — наоборот, правильно:
    **Settings → Repository → Protected tags → `v*`**, иначе теговый пайплайн тоже не увидит переменную.

**File-переменная**: GitLab кладёт содержимое во временный файл, а в переменной — **путь** к нему.
Поэтому `cat "$YC_CI_KEY"`, а для `KUBECONFIG` это ровно то, что ждут kubectl и helm.

Значения взяты из Terraform и кластера:

```bash
terraform output -raw registry_url        # cr.yandex/<id> → YC_REGISTRY_ID = <id>
terraform output -raw static_base_url     # → IMAGES_BASE_URL
terraform output -raw ci_sa_key_json      > ~/.config/yandex-cloud/momo-ci-key.json
k8s-addons/ci-access/make-kubeconfig.sh   > ~/.config/yandex-cloud/momo-kubeconfig-ci
pbcopy < ~/.config/yandex-cloud/momo-ci-key.json     # вставить в Value
```

## Авторизация в Yandex Container Registry

Логин `json_key`, пароль — **весь JSON** авторизованного ключа сервисного аккаунта.
Без `yc` и без IAM-токенов, которые живут 12 часов.

```yaml
.kaniko-build:
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug   # debug-вариант — есть shell
    entrypoint: [""]
  script:
    - if [ -n "$CI_COMMIT_TAG" ]; then VERSION="${CI_COMMIT_TAG#v}"; else VERSION="0.0.0-${SHA_TAG}"; fi
    - mkdir -p /kaniko/.docker
    - AUTH=$(printf "json_key:%s" "$(cat "$YC_CI_KEY")" | base64 | tr -d '\n')
    - echo "{\"auths\":{\"cr.yandex\":{\"auth\":\"${AUTH}\"}}}" > /kaniko/.docker/config.json
    - >-
      /kaniko/executor
      --context "${CI_PROJECT_DIR}/${COMPONENT_DIR}"
      --dockerfile "${CI_PROJECT_DIR}/${COMPONENT_DIR}/Dockerfile"
      --build-arg "VERSION=${VERSION}"
      --label "org.opencontainers.image.revision=${CI_COMMIT_SHA}"
      --destination "${IMAGE}:${SHA_TAG}"
```

Тот же `config.json` используют trivy и crane (`crane auth login cr.yandex -u json_key -p "$(cat $YC_CI_KEY)"`),
Helm — `helm registry login cr.yandex -u json_key --password-stdin < "$YC_CI_KEY"`.

!!! warning "TRIVY_USERNAME / TRIVY_PASSWORD не подходят"
    Trivy понимает их как **списки через запятую**, а в JSON-ключе много запятых →
    `the number of usernames and passwords must match`. Подробно — в [журнале проблем](diploma-troubleshooting.md).

## Стадия test

```yaml
backend-unit-test:
  image: golang:1.23                      # не alpine: для -race нужен cgo (gcc)
  needs: []                               # не ждать build
  variables: { GOPATH: ${CI_PROJECT_DIR}/.go }
  cache: { key: go-mod, paths: [.go/pkg/mod/] }
  script:
    - cd backend
    - go vet ./...
    - go test -race -count=1 -coverprofile=coverage.out ./...
    - go tool cover -func=coverage.out | tail -1
  coverage: '/total:\s+\(statements\)\s+(\d+\.\d+)%/'     # 26.4% — видно в списке задач

.trivy-scan:
  script:
    - trivy image --exit-code 0 --severity HIGH,CRITICAL --ignore-unfixed "${IMAGE}:${SHA_TAG}"   # отчёт
    - trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed "${IMAGE}:${SHA_TAG}"        # блок

helm-lint:
  script:
    - helm lint . --set global.imageTag=0.0.0-lint
    - helm template momo-store . -f ../values-prod.yaml --set global.imageTag=0.0.0-lint
        --api-versions monitoring.coreos.com/v1/ServiceMonitor | kubeconform -strict -summary -ignore-missing-schemas

terraform-validate:
  image: { name: hashicorp/terraform:1.9.8, entrypoint: [""] }
  variables: { TF_CLI_CONFIG_FILE: ${CI_PROJECT_DIR}/infrastructure/terraform/.terraformrc }
  script:
    - terraform fmt -recursive -check -diff
    - for dir in bootstrap envs/prod; do terraform -chdir=$dir init -backend=false && terraform -chdir=$dir validate; done
```

* `--ignore-unfixed` — блокируем только то, что **можно** исправить (есть фикс-версия).
* `frontend-audit` (`npm audit`) — `allow_failure: true`: зависимости фронтенда менять нельзя.
* `init -backend=false` — валидация без доступа к state и без секретов.
* Coverage 26,4 % — тесты из исходников, свои не добавлял (исходники не трогаем).

## Стадия release (только тег)

```yaml
release-images:
  image: { name: gcr.io/go-containerregistry/crane:debug, entrypoint: [""] }
  script:
    - VERSION="${CI_COMMIT_TAG#v}"
    - crane auth login cr.yandex -u json_key -p "$(cat "$YC_CI_KEY")"
    - |
      for image in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
        crane tag "${image}:${SHA_TAG}" "${VERSION}"        # без pull/push слоёв — новый тег на тот же digest
        echo "${image}:${VERSION} -> $(crane digest "${image}:${VERSION}")"
      done

release-chart:
  script:
    - helm registry login cr.yandex -u json_key --password-stdin < "$YC_CI_KEY"
    - helm package . --version "$VERSION" --app-version "$VERSION"
    - helm push "momo-store-${VERSION}.tgz" "$CHART_REPO"     # → cr.yandex/<id>/charts/momo-store:0.1.0
```

**Build once:** на теге образ собирается для коммита тега, проходит test, и на release тот же digest
получает SemVer-тег. В отличие от репо 2022 (`1.0.${CI_PIPELINE_ID}` + `latest`) — версия осмысленная,
а в проде ровно протестированный образ.

### Release Notes

`ci/scripts/release-notes.sh` собирает Markdown из git с предыдущего тега:

```bash
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${tag}^" 2>/dev/null || true)
range="${prev:+${prev}..}${tag}"          # первый релиз — вся история

# merge-коммит GitLab:
#   Merge branch 'feature/x' into 'master'
#
#   <заголовок MR>
#
#   See merge request group/project!12
git log --merges --format=%H "$range" | while read -r sha; do
  body=$(git log -1 --format=%b "$sha")
  iid=$(printf '%s\n' "$body" | grep -oE 'See merge request [^ ]+![0-9]+' | grep -oE '[0-9]+$')
  title=$(printf '%s\n' "$body" | sed '/^$/d' | head -1)
  authors=$(git log --format=%an "${sha}^1..${sha}^2" | sort -u)   # авторы коммитов ветки MR
  echo "- ${title} ([!${iid}](${CI_PROJECT_URL}/-/merge_requests/${iid})) — ${authors}"
done
```

Разделы: Merge Requests (заголовок, ссылка, авторы), Коммиты, Авторы, Артефакты (образы и чарт).
`git log A^1..A^2` — коммиты, которые пришли в merge-коммит из второго родителя, то есть из ветки MR.

Для работы нужна полная история: `variables: { GIT_DEPTH: "0" }`.

Релиз создаётся через API:

```bash
payload=$(jq -n --arg tag "$CI_COMMIT_TAG" --arg name "Momo Store ${CI_COMMIT_TAG}" \
  --rawfile desc release-notes.md '{tag_name: $tag, name: $name, description: $desc}')
curl --fail-with-body -X POST -H "JOB-TOKEN: ${CI_JOB_TOKEN}" -H "Content-Type: application/json" \
  --data "$payload" "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/releases"
```

Если GitLab не пускает `CI_JOB_TOKEN` — переменная `RELEASE_TOKEN` (project access token, scope `api`),
скрипт подставит `PRIVATE-TOKEN`.

## Стадия deploy и автооткат

```yaml
deploy-production:
  image: ${K8S_IMAGE}
  rules: [{ if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/' }]
  resource_group: production              # два деплоя не идут одновременно
  environment: { name: production, url: ${APP_URL} }
  script:
    - VERSION="${CI_COMMIT_TAG#v}"
    - helm registry login cr.yandex -u json_key --password-stdin < "$YC_CI_KEY"
    - >-
      helm upgrade --install momo-store "${CHART_REPO}/momo-store"
      --version "$VERSION" --namespace momo-store
      -f infrastructure/helm/values-prod.yaml
      --set global.registry="$REGISTRY"
      --set global.imageTag="$VERSION"
      --set frontend.imagesRewrite.to="$IMAGES_BASE_URL"
      --atomic --wait --timeout 5m --history-max 10
    - helm history momo-store -n momo-store --max 5
    - ci/scripts/smoke-test.sh "$APP_URL" || { helm rollback momo-store -n momo-store --wait; exit 1; }
```

Два уровня отката:

1. **`--atomic`** — если новые поды не стали Ready за `--timeout` (readiness-проба не проходит,
   CrashLoopBackOff, образ не скачался), Helm сам откатывает релиз на предыдущую ревизию.
2. **Smoke-тест** снаружи через Ingress — если поды Ready, но приложение не отвечает
   (сломан роутинг, nginx-конфиг) — явный `helm rollback`.

```bash
# smoke-test.sh: до 10 попыток с паузой 6 с
check "/momo-store/"    '<div id="app"'
check "/api/products"   '"results"'
check "/api/categories" '"id"'
```

Деплоится **чарт из реестра** (`oci://...`, `--version`), а не из рабочей копии — та же версия, что в релизе.

!!! tip "Как проверить автооткат (звёздочка)"
    В ветке поменять `readinessProbe.httpGet.path` backend на `/broken`, влить, выпустить `v0.1.1`.
    Поды не станут Ready → `--atomic` вернёт `0.1.0` → пайплайн красный → уведомление в Telegram.
    `helm history momo-store -n momo-store` покажет ревизию отката. Потом вернуть путь и выпустить `v0.1.2`.

## Уведомления: Telegram и почта

!!! warning "Telegram Bot API недоступен из российских дата-центров"
    С раннеров Практикума и из Yandex Cloud `api.telegram.org` таймаутит. Поэтому два канала, оба с
    `allow_failure: true`: Telegram (сработает с прокси или из другой сети) и **почта через SMTP Яндекса**
    (`notify-email-success` / `notify-email-failure`, переменные `SMTP_USER`, `SMTP_PASSWORD` — пароль
    приложения, Masked, `MAIL_TO`). Подробно — [журнал проблем](diploma-troubleshooting.md), № 18–21.


```yaml
notify-success:
  stage: .post
  rules: [{ if: '$TELEGRAM_BOT_TOKEN && $TELEGRAM_CHAT_ID', when: on_success }]
  script: [ci/scripts/telegram.sh success]

notify-failure:
  stage: .post
  rules: [{ if: '$TELEGRAM_BOT_TOKEN && $TELEGRAM_CHAT_ID', when: on_failure }]
  script: [ci/scripts/telegram.sh failed]
```

* `.post` — встроенная стадия, всегда последняя.
* `when: on_failure` — задача запускается, только если **что-то раньше упало**.
* Без переменных `TELEGRAM_*` задачи просто не создаются.
* Скрипт шлёт `sendMessage` с `parse_mode=HTML` и экранирует `& < >` в заголовке коммита.

Бот: `@BotFather` → `/newbot` → токен; написать боту; `https://api.telegram.org/bot<TOKEN>/getUpdates` → `chat.id`.

## Как прошёл первый релиз

```bash
git switch master && git pull --ff-only
git tag -a v0.1.0 -m "Momo Store 0.1.0"
git push origin v0.1.0
```

Наблюдение со стороны облака (доступа к API GitLab не было):

```bash
yc container image list --registry-id <registry_id> --format json \
  | jq -r '.[] | select(.tags | index("0.1.0")) | .name'
helm -n momo-store list
# momo-store  momo-store-0.1.0  deployed
```

## Шпаргалка

| Что | Как |
|---|---|
| Где пайплайны | Build → Pipelines |
| Включить CI/CD в форке | Settings → General → Visibility, project features → **CI/CD** |
| Раннеры | Settings → CI/CD → Runners (instance-раннер, online, теги) |
| Переменные | Settings → CI/CD → Variables |
| Защитить ветку / теги | Settings → Repository → Protected branches / tags |
| Релизы | Deploy → Releases |
| Окружения и история деплоев | Operate → Environments |
| Убрать строку из сообщений уже запушенных коммитов | `git filter-branch --msg-filter 'sed "/^Строка/d" \| git stripspace' master..HEAD` + `git push --force-with-lease` |
