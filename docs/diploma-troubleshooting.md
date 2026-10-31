# Диплом: журнал проблем

Реальные проблемы, которые встретились при выполнении диплома, в порядке появления.
Формат: **симптом → диагностика → причина → решение → вывод**.
Общий обзор — [на главной странице раздела](diploma-momo-store.md).

!!! tip "Главный урок"
    Почти ничего из этого не было ошибкой в коде. Время уходит на окружение: биллинг, квоты,
    настройки GitLab, базовые образы. Навык — быстро понять, **в каком слое** проблема,
    и проверить гипотезу одной командой.

## 1. Исходники менять нельзя

**Симптом.** Решение было построено на правках кода: новые метрики в backend
(`http_requests_total{status}`), переменная `IMAGES_BASE_URL` для картинок, `publicPath: '/'` во фронтенде.
Требование: исходный код должен остаться как в форке.

**Решение — всё снаружи:**

| Было (правка кода) | Стало |
|---|---|
| backend отдаёт ссылки на S3 | nginx фронтенда проксирует `/api` и подменяет ссылки `sub_filter` |
| `publicPath: '/'` | бандл кладётся в `/momo-store/`, корень редиректит туда |
| метрики с кодом ответа | Errors — из метрик ingress-nginx по Ingress `*-api` |
| Ingress `/api` → backend с `rewrite-target` | Ingress `/api` → frontend; backend доступен только из frontend |
| правки корневого `.gitignore` | новый `infrastructure/.gitignore` |

```bash
git checkout -- backend/ frontend/vue.config.js .gitignore    # вернуть как было
git diff --stat -- backend frontend .gitignore                # пусто = не тронуто
```

**Вывод.** Сначала выяснить ограничения задания, потом проектировать. Ограничение «не трогать
код приложения» — типичное для DevOps: приложение чужое, инфраструктура подстраивается под него.

## 2. Terraform нет в Homebrew

**Симптом.** `brew install terraform` → `No available formula with the name "terraform"`.

**Причина.** После смены лицензии HashiCorp на BSL Terraform убрали из `homebrew-core`.

**Решение.**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Альтернатива — OpenTofu (`brew install opentofu`, команда `tofu`), совместим по синтаксису.

## 3. `yc` не находится в fish

**Симптом.** После установки `yc init` → `fish: Unknown command: yc`.

**Причина.** Установщик прописывает PATH только в bash/zsh. Команду `fish -c 'fish_add_path ...'`
выполнял в отдельном процессе fish — в текущий терминал она не попала.

**Решение.** В своём терминале напрямую:

```fish
fish_add_path ~/yandex-cloud/bin
# если не помогло (fish_user_paths переопределяется в config.fish):
echo 'fish_add_path -g ~/yandex-cloud/bin' >> ~/.config/fish/config.fish
```

## 4. `registry.terraform.io/hashicorp/yandex` — нет такого провайдера

**Симптом.** `terraform init` в `envs/prod`:
`This configuration requires provider registry.terraform.io/hashicorp/yandex`.

**Причина.** В модулях не был объявлен `required_providers`. Без него Terraform считает, что
провайдер `yandex` — из namespace `hashicorp`.

**Решение.** В каждом модуле `versions.tf`:

```hcl
terraform {
  required_providers {
    yandex = { source = "yandex-cloud/yandex" }
  }
}
```

Версию пинить в корне (`~> 0.140`), в модулях — только `source`.

## 5. Бакет не создаётся: AccessDenied

**Симптом.** Bootstrap: 4 ресурса из 5 созданы, на бакете
`error creating Storage S3 Bucket: AccessDenied: Access Denied`. Повтор — то же.

**Диагностика.**

```bash
yc resource-manager folder list-access-bindings <folder_id>    # у SA terraform есть admin — права ок
yc storage bucket create --name test-bucket-xyz                # от СВОЕГО имени — тоже PermissionDenied!
yc quota-manager quota-limit list --service storage \
  --resource-type resource-manager.cloud --resource-id <cloud_id>
# NoSuchCloud: The specified cloud does not exist.
```

Владелец облака не может создать бакет, а сервис Object Storage «не знает» облако → дело не в правах.

**Причина.** К облаку не был привязан **платёжный аккаунт**. IAM бесплатный и работает без биллинга
(поэтому SA и ключи создались), Object Storage — нет.

**Решение.** Консоль → Биллинг: платёжный аккаунт в статусе ACTIVE, облако привязано, грант виден.
После привязки — **подождать несколько минут**, пока сервисы получат информацию (первый повтор сразу
после привязки снова дал AccessDenied). Проверка тестовым бакетом → `terraform apply` → бакет создан.

**Вывод.** «Access denied» от облака — не всегда про IAM. Проверить тем же действием от владельца:
если и он не может, проблема на уровне аккаунта (биллинг, квоты, сервис не активирован).

## 6. Узлы не создаются: квоты

**Симптом.** `terraform apply`: 37 из 38 ресурсов готовы, группа узлов
`Still creating... [27m46s elapsed]`. Кластер при этом `RUNNING / HEALTHY`.

**Диагностика.**

```bash
yc managed-kubernetes node-group get <name> --format json | jq .status        # PROVISIONING
yc managed-kubernetes node-group list-nodes <name>
# DELETED [RESOURCE_EXHAUSTED] The limit on total size of network-hdd disks has exceeded for zone "ru-central1-a"
yc quota-manager quota-limit list --service compute \
  --resource-type resource-manager.cloud --resource-id <cloud_id> --format json \
  | jq -r '.quota_limits[] | select(.quota_id|test("ru-central1-a")) | "\(.quota_id)\t\(.limit)"'
```

Стартовые квоты на зону: **2 vCPU, 16 ГБ RAM, 20 ГБ HDD, 10 ГБ SSD** — меньше одного узла
(2 vCPU + диск 64 ГБ), а нужно два.

**Решение.** Консоль → облако → Квоты → **Compute Cloud** → зона `ru-central1-a`:
vCPU 2 → 4, HDD 20 → 150 ГБ (RAM 16 ГБ хватало). Одобрили автоматически за минуты.
Группа узлов **досоздалась сама** — `apply` дождался и завершился (итого 44 мин).
`node_max_count` уменьшил с 3 до 2 под квоты.

!!! note "Не та квота"
    Сначала увеличил «Количество облачных сетей» (VPC) — проект использует одну сеть из двух,
    это ни на что не влияло. Ошибка явно называла **network-hdd** → Compute Cloud.

**Вывод.** Если Terraform долго «Still creating» — смотреть состояние ресурса в самом облаке,
там видна настоящая ошибка. Сравнение с репо 2022 года: там те же 4 vCPU и 128 ГБ HDD —
просто у автора были выше стартовые квоты.

## 7. После переноса state: «No valid credential sources found»

**Симптом.** После `terraform init -migrate-state` любой `terraform output` / `plan`:

```
Error: No valid credential sources found
failed to refresh cached credentials, no EC2 IMDS role found ... 169.254.169.254 ... host is down
```

**Причина.** State теперь в S3 — чтобы его прочитать, нужны `AWS_ACCESS_KEY_ID/SECRET`. Без них
S3-backend (код AWS SDK) пытается найти роль через метаданные EC2.

**Решение.** S3-ключи сохранить в `~/.config/yandex-cloud/momo-s3.env` **до** удаления локального
state (достал из `terraform.tfstate.backup` через `jq`), затем:

```bash
set -a; . ~/.config/yandex-cloud/momo-s3.env; set +a
terraform plan        # No changes
```

## 8. Deprecated `cluster_ipv4_range`

**Симптом.** `Warning: Argument is deprecated ... Use cluster_ipv4_ranges instead.`

**Диагностика** — схема ресурса прямо из провайдера:

```bash
terraform providers schema -json | jq -c '.provider_schemas[].resource_schemas.yandex_kubernetes_cluster.block.attributes
  | to_entries[] | select(.key|test("ipv4")) | {k:.key, type:.value.type, dep:.value.deprecated}'
# {"k":"cluster_ipv4_range","type":"string","dep":true}
# {"k":"cluster_ipv4_ranges","type":["list","string"],"dep":null}
```

**Решение.** `cluster_ipv4_ranges = [var.cluster_ipv4_range]` — до создания кластера, чтобы не было изменений потом.

## 9. kubectl: «current-context is not set»

**Симптом.** После `yc managed-kubernetes cluster get-credentials ... --external --force`:
`error: current-context is not set`, `The connection to the server localhost:8080 was refused`.

**Диагностика.**

```bash
echo $KUBECONFIG          # ./ya_kc.yaml — осталась с прошлых спринтов
grep current-context ~/.kube/config     # yc-momo-store — yc записал сюда
```

**Причина.** `yc` пишет в `~/.kube/config`, а kubectl читает файл из `$KUBECONFIG`
(относительный путь, файла в текущей папке нет → пустой конфиг → localhost:8080).

**Решение.**

```fish
set -x KUBECONFIG ~/.kube/config
```

или убрать старую переменную из `~/.config/fish/config.fish`.

## 10. В форке нет CI/CD

**Симптом.** В Settings нет пункта CI/CD.

**Причина.** У форков GitLab часто отключает функцию CI/CD.

**Решение.** Settings → General → **Visibility, project features, permissions** → включить **CI/CD** → Save.
Затем Settings → CI/CD → Runners: у Практикума есть общий **instance-раннер** (online) — свой не нужен.

Если раннера нет — запасной план: свой раннер в кластере через Helm-чарт `gitlab/gitlab-runner`
с kubernetes executor (ресурсы узлов позволяли: CPU 5–6 %, память 22–34 %).

## 11. Protected на переменной, нужной веткам

**Симптом (предотвращён).** Все переменные заведены с флагом Protected, включая `YC_REGISTRY_ID`.

**Причина.** Protected-переменные доступны только пайплайнам **защищённых** веток и тегов.
Пайплайн `feature/*` получил бы `REGISTRY=cr.yandex/` и упал на push образа.

**Решение.** Protected снять с `YC_REGISTRY_ID` (и не ставить на `YC_CI_KEY`), оставить на
`KUBECONFIG`, `APP_URL`, `IMAGES_BASE_URL` — они нужны только деплою с защищённого тега `v*`.

## 12. Trivy: «the number of usernames and passwords must match»

**Симптом.** `backend-image-scan` и `frontend-image-scan`:

```
FATAL  flag error: unable to convert flags to options: the number of usernames and passwords must match
```

**Причина.** `TRIVY_USERNAME` / `TRIVY_PASSWORD` — **списки через запятую** (несколько реестров).
Пароль — JSON-ключ SA, в нём десятки запятых → 1 логин и много «паролей».

**Решение.** Авторизация через docker config, как у kaniko:

```yaml
script:
  - mkdir -p "$HOME/.docker"
  - AUTH=$(printf "json_key:%s" "$(cat "$YC_CI_KEY")" | base64 | tr -d '\n')
  - echo "{\"auths\":{\"cr.yandex\":{\"auth\":\"${AUTH}\"}}}" > "$HOME/.docker/config.json"
  - trivy image ...
```

Проверил локально тем же образом trivy против реального реестра до push.

**Полезный побочный вывод:** задачи сканирования стартуют после build — значит, сборка и push
в реестр уже работали.

## 13. Критические CVE в базовых образах

**Симптом.** После исправления авторизации trivy нашёл реальное:

| Образ | Уязвимость | Где | Исправлено в |
|---|---|---|---|
| backend | CVE-2025-68121 | Go stdlib 1.23.12 | Go 1.24.13 / 1.25.7 |
| frontend | CVE-2026-111497 | `brotli-libs` | 1.1.1-r0 |
| frontend | CVE-2026-31789 | `libcrypto3`, `libssl3` | 3.3.7-r0 |

Даже свежие `nginx-unprivileged:1.28-alpine` и `1.29-alpine` содержали уязвимые пакеты — исправления
уже были в репозиториях Alpine, но ещё не в базовом образе.

**Решение — без изменения исходников:**

* backend — сборка компилятором `golang:1.25-alpine`. `go 1.23` в `go.mod` — минимальная версия,
  `go.mod` не меняется;
* frontend — `nginx-unprivileged:1.29-alpine` + `apk upgrade --no-cache` под `USER root`, затем `USER 101`.

```bash
# проверка до push: собрать под linux/amd64 и просканировать архив
docker build --platform linux/amd64 -t momo-frontend:scan frontend
docker save momo-frontend:scan -o fe.tar
docker run --rm -v $PWD:/s aquasec/trivy:0.67.2 image --input /s/fe.tar --severity CRITICAL --ignore-unfixed --exit-code 1
```

**Вывод.** Сканер в CI сразу окупился. `--ignore-unfixed` — разумный порог: блокировать то,
что реально можно исправить.

## 14. Пустые панели ingress на дашборде

**Симптом.** Метрики backend есть, а `nginx_ingress_controller_requests` — пусто.
Таргет ingress-nginx при этом `up = 1`.

**Диагностика.**

```bash
# какие метрики ingress вообще есть
.../api/v1/label/__name__/values | jq -r '.data[]' | grep ^nginx_ingress
# есть *_nginx_process_*, admission_*, config_* — но нет requests и request_duration
kubectl -n ingress-nginx get deploy ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}'
```

**Причина.** ingress-nginx по умолчанию пишет метрики запросов **только для хостов из правил Ingress**
(защита от кардинальности). У нас Ingress без `host` — доступ по IP.

**Решение.**

```yaml
controller:
  extraArgs:
    metrics-per-host: "false"
```

`helm upgrade` → после трафика: `["momo-store-api 200=20","momo-store-frontend 200=20"]`.

## 15. Grafana: ChunkLoadError и «Error loading: stat»

**Симптом.** В браузере:
`ChunkLoadError: Loading chunk 70133 failed`, затем на панелях `Error loading: stat ... If this plugin was loaded from Git...`.

**Диагностика.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<ingress_ip>/grafana/public/build/70133....js   # 200 — сейчас отдаётся
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana    # 3/3 Running, RESTARTS 2 (22s ago)
kubectl -n monitoring get pod <grafana> -o json \
  | jq -r '.status.containerStatuses[] | "\(.name) \(.restartCount) \(.lastState.terminated.reason)"'
# grafana 2 OOMKilled
kubectl top pod -n monitoring --containers | grep grafana        # 250Mi при лимите 256Mi
```

**Причина.** Лимит памяти Grafana 256Mi — мало для Grafana 13 со стандартными дашбордами.
Контейнер убивало OOM; браузер в момент рестарта не дозагрузил JS-чанки. После рестарта сессия
(в SQLite внутри пода) пропала → в логах `user token not found`, а старая вкладка показывала
`Error loading: stat` (встроенная панель Stat — плагин на месте).

**Решение.** `requests.memory: 256Mi`, `limits.memory: 512Mi` → `helm upgrade` →
**Cmd+Shift+R** и вход заново.

**Вывод.** Странные ошибки фронтенда веб-приложения в кластере — сначала проверить
**рестарты пода** и `lastState.terminated.reason`.

## 16. Обработчик прерываний долго в ContainerCreating

**Симптом.** Поды `preemptible-handler` минуты в `ContainerCreating`, `kubectl exec` —
`container not found`.

**Причина.** Образ `alpine/k8s` ~500 МБ, качается через NAT. Не ошибка — через пару минут
`watching preemption notice` в логах.

**Можно лучше.** Свой маленький образ (`alpine` + `curl` + `kubectl`) или `bitnami`-подобный
с одним kubectl — быстрее старт после прерывания узла.

## 17. Лишняя строка в сообщениях уже запушенных коммитов

**Задача.** Убрать строку-трейлер из сообщений двух коммитов, которые уже на сервере (в своей feature-ветке).

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --msg-filter 'sed "/^Co-Authored-By:/d" | git stripspace' master..HEAD
git diff <старый_sha> HEAD --stat          # пусто — содержимое не изменилось
git update-ref -d refs/original/refs/heads/<ветка>
git push --force-with-lease origin <ветка>
```

* `master..HEAD` — переписать только коммиты ветки, `master` не трогать.
* `git stripspace` — убрать оставшиеся пустые строки в конце.
* `--force-with-lease` — не затереть чужие изменения, если ветку кто-то обновил.
* Хэши коммитов меняются; на чужой (общей) ветке так делать нельзя без договорённости.

## 18. Telegram Bot API недоступен из российских дата-центров

**Симптом.** Задача `notify-success`:

```
$ ci/scripts/telegram.sh "$PIPELINE_STATUS"
curl: (28) Connection timed out after 10001 milliseconds
```

**Диагностика** — сравнить, откуда доступно:

```bash
curl -s -o /dev/null -w "%{http_code} %{time_connect}s\n" --max-time 15 https://api.telegram.org/   # с Mac: 302
kubectl run tg-probe -n default --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- \
  sh -c 'nslookup api.telegram.org; curl -sS --max-time 12 https://api.telegram.org/; \
         curl -s -o /dev/null -w "github: %{http_code}\n" https://api.github.com/'
route -n get api.telegram.org | grep interface     # на Mac: utun4 — трафик идёт через VPN
```

| Откуда | `api.telegram.org` | Остальной интернет |
|---|---|---|
| Mac (через VPN) | 302 | ✅ |
| Под в Yandex Cloud | таймаут (и по имени, и по IP `149.154.167.220`) | GitHub 200 |
| Раннер GitLab Практикума | таймаут | ✅ |

**Причина.** DNS отвечает, но TCP-соединение до серверов Telegram из российских ДЦ не устанавливается.
Токен и код ни при чём.

**Что не подходит:**

* `tg-ws-proxy`, ссылки `t.me/proxy?server=...&secret=...` — это **MTProto**-прокси для приложений Telegram.
  Bot API — обычный HTTPS, а `curl -x` понимает только HTTP/SOCKS. Через MTProto бот может работать
  только через библиотеку клиента (Telethon: вход по `bot_token` + `api_id/api_hash` + MTProxy) — отдельный проект.
* Интеграция Telegram в GitLab — сервер GitLab Практикума тоже в Yandex Cloud.

!!! warning "secret в ссылке MTProto-прокси — это пароль"
    Не публиковать ссылку в README, конспекте, логах CI.

**Решение:**

1. `allow_failure: true` в шаблоне `.telegram` — недоступный канал не красит пайплайн релиза.
2. Резервный канал — **почта через SMTP**: `smtp.yandex.ru:465` из облака доступен.
3. Поддержка `TELEGRAM_PROXY` (HTTP/SOCKS) — если появится обычный прокси за рубежом: `curl ${TELEGRAM_PROXY:+-x "$TELEGRAM_PROXY"} ...`.
4. Описать ограничение в README и спросить куратора, как засчитывается звёздочка.

**Вывод.** Если внешний сервис «таймаутит» только из CI — проверить из того же сегмента сети
(под в кластере), сравнить с другим сайтом и с локальной машиной; посмотреть, не через VPN ли работает локально.

## 19. `when: allow_failure` — такого значения нет

**Симптом.** Первая попытка сделать уведомления необязательными:

```yaml
rules:
  - if: $TELEGRAM_BOT_TOKEN && $TELEGRAM_CHAT_ID
    when: allow_failure        # ✗
```

**Причина.** `when` решает, **когда** запускать задачу: `on_success`, `on_failure`, `always`, `manual`,
`delayed`, `never`. `allow_failure` — отдельный ключ задачи (как `stage`, `image`). К тому же так
потерялась бы разница между `notify-success` (`on_success`) и `notify-failure` (`on_failure`).

**Решение** — одна строка в общем шаблоне, `when` не трогать:

```yaml
.telegram:
  stage: .post
  allow_failure: true      # действует на все задачи с extends: .telegram
```

Валидность `.gitlab-ci.yml` можно проверить заранее: Build → Pipeline editor → Validate (или CI Lint).

## 20. После merge пайплайна нет вообще

**Симптом.** MR с изменениями только в `ci/notify.yml`, `ci/scripts/email.sh` и `README.md`:
ни пайплайна MR, ни пайплайна `master` после merge — и письма нет.

**Причина.** У всех задач build/test есть `rules: changes` по своим каталогам — под эти файлы не подошла
ни одна. Остались бы только задачи `.post` (уведомления), а **GitLab не создаёт пайплайн, в котором только
`.pre`/`.post` задачи** — он считается пустым.

**Решение.** Для проверки — Build → Pipelines → **Run pipeline** на нужной ветке: при ручном запуске
(`CI_PIPELINE_SOURCE = web`) `changes` считаются выполненными, запускается всё.
Если важно, чтобы правки CI всегда запускали проверки — добавить `ci/**/*` в `changes` ключевых задач.

## 21. Уведомления по почте через SMTP из CI

Не проблема, а рабочий рецепт — `curl` умеет SMTP, отдельный образ не нужен:

```bash
encoded_subject="=?UTF-8?B?$(printf '%s' "$subject" | base64 | tr -d '\n')?="   # кириллица в заголовке — RFC 2047

cat > mail.txt <<MAIL
From: momo-store CI <${SMTP_USER}>
To: <${MAIL_TO}>
Subject: ${encoded_subject}
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

Текст письма...
MAIL

curl -sS --fail --max-time 30 --ssl-reqd --crlf \
  --url smtps://smtp.yandex.ru:465 \
  --user "${SMTP_USER}:${SMTP_PASSWORD}" \
  --mail-from "$SMTP_USER" --mail-rcpt "$MAIL_TO" \
  --upload-file mail.txt
```

| Деталь | Зачем |
|---|---|
| `smtps://...:465` + `--ssl-reqd` | TLS сразу (implicit TLS); для 587 — STARTTLS |
| `--crlf` | SMTP требует переводы строк CRLF |
| `From` = логин | Яндекс не даёт отправлять от чужого адреса |
| **Пароль приложения** | Яндекс ID → Безопасность → Пароли приложений → Почта; основной пароль в CI не класть. В Почте включить «Почтовые программы» → IMAP и пароли приложений |
| `SMTP_PASSWORD` — Masked | не светить в логах |

Проверки:

* доступность порта — `curl -s -o /dev/null -w '%{time_connect}' smtp://smtp.yandex.ru:587/` (ответ 502 = сервер жив, ждёт TLS/авторизацию);
* TLS и авторизация — отправка с ложным паролем → `curl: (67) Login denied`: значит, всё, кроме пароля, верно;
* содержимое без отправки — режим `EMAIL_DRY_RUN=1` в скрипте.

## Чек-лист диагностики

| Уровень | Чем проверить |
|---|---|
| Аккаунт облака (биллинг, квоты) | то же действие от владельца; `yc quota-manager quota-limit list` |
| Ресурс в облаке | `yc <service> ... get/list` — там видна настоящая ошибка, а не «Still creating» |
| Terraform | `plan`, `state list`, `providers schema -json` |
| Kubernetes | `get pods -A`, `describe`, `lastState.terminated.reason`, `top`, `events` |
| Сеть / Ingress | `curl -w '%{http_code}'` снаружи, `kubectl run curl` изнутри |
| Метрики | `up{}`, список `__name__`, запрос в API Prometheus |
| CI | лог задачи, флаги переменных, раннер и его теги, `rules: changes`, только ли `.post`-задачи в пайплайне |
| Внешний сервис из CI | тот же запрос из пода в кластере и локально; сравнить с другим сайтом; локально — не через VPN ли |
| Окружение | `echo $KUBECONFIG`, `which`, версия инструмента |
