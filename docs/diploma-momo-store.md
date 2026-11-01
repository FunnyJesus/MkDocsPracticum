# Дипломный проект: Momo Store

Итоговый проект курса DevOps: построить **полный релизный цикл** двухкомпонентного приложения
«Пельменная №2» — от коммита до работающего сервиса в Yandex Cloud.

Раздел — подробный журнал того, как задание было выполнено: какие решения приняты и почему,
какие команды запускались, на какие грабли наступил и как их обошёл.

| Страница | О чём |
|---|---|
| **Обзор** (эта страница) | задание, архитектура, ключевые решения, структура репо, статус |
| [Terraform и облако](diploma-terraform.md) | bootstrap, remote state, модули, квоты и биллинг, пошаговые команды |
| [Образы, Helm и кластер](diploma-k8s.md) | Dockerfile'ы, nginx как шлюз, Helm-чарт, платформа, прерываемые узлы, zero-trust |
| [CI/CD в GitLab](diploma-cicd.md) | стадии, переменные и флаги, build once, release notes, автооткат, Telegram |
| [Мониторинг](diploma-monitoring.md) | метрики backend и ingress, R.E.D.-дашборд, PromQL |
| [Журнал проблем](diploma-troubleshooting.md) | 25 записей: симптом → диагностика → причина → решение |
| [Вопросы для защиты](diploma-defense.md) | самопроверка: что спросит ревьюер и как ответить |

## Задание кратко

Приложение **Momo Store**:

* **backend** на Go — REST API (`/products`, `/categories`, `/orders`, `/auth/*`), `/health` и `/metrics`;
* **frontend** на Vue.js — SPA, ходит в backend по REST.

Что нужно было сделать:

1. Структура репозитория и стратегия ветвления (Git Flow / Trunk-Based / GitHub Flow).
2. Оптимизированные Docker-образы → Container Registry с **версионными тегами**.
3. Terraform → Yandex Cloud: **Kubernetes-кластер**, **S3** для state Terraform и раздачи статики.
4. Helm-чарты, деплой в кластер.
5. GitLab CI: сборка, тесты, развёртывание.
6. Наблюдаемость: Prometheus + Grafana, метрики **R.E.D.** или Golden Signals.
7. README: архитектура, ветвление, версионирование, пошаговые инструкции.

Сдача в две итерации:

* **Итерация 1** — инфраструктура развёрнута, конвейер build + test, образы в реестре, приложение отвечает;
* **Итерация 2** — полный CI/CD (build → test → release → deploy), авто-деплой, чарты с пробами
  и ресурсами, дашборд, README.

Задачи со звёздочкой: автооткат, уведомления в Telegram, Release Notes, HPA, zero-trust.

!!! warning "Главное ограничение"
    **Исходный код приложения (`backend/`, `frontend/`) менять нельзя** — он должен остаться как в форке.
    Всё, что нужно облаку, делается снаружи: Dockerfile'ы, конфигурация nginx, Helm-чарт, Terraform, CI.
    Сначала я поправил код (метрики, URL картинок, `publicPath`) — пришлось всё откатить и решить
    задачи по-другому. Подробно — в [журнале проблем](diploma-troubleshooting.md) (проблема № 1).

## Архитектура

```
                    Интернет
                       │
          Network Load Balancer (статический IP)
                       │
┌──────────────── Managed Kubernetes (2 прерываемых узла) ─────────────────┐
│                      ▼                                                    │
│               ingress-nginx  ──── /grafana ───► Grafana ◄── Prometheus    │
│                 │       │                                    │   │        │
│          "/"    │       │  "/api"                    scrape  │   │        │
│                 ▼       ▼                                    │   │        │
│        ┌─── frontend (nginx + exporter) ◄────────────────────┘   │        │
│        │        │  /api/* → /*  +  подмена ссылок на картинки     │        │
│        │        ▼                                                │        │
│        │     backend (Go :8081) ◄─────────────── scrape /metrics ┘        │
│        │                                                                  │
│   preemptible-handler (DaemonSet) — drain узла перед прерыванием          │
└───────────────────────────────────────────────────────────────────────────┘
        │ картинки                        ▲ pull образов
        ▼                                 │
  Object Storage (публичный бакет)   Container Registry ◄── GitLab CI (push образов и чартов)
  Object Storage (приватный бакет с tfstate)
```

| Компонент | Реализация |
|---|---|
| Кластер | Managed Kubernetes 1.34, **зональный** мастер, 2 **прерываемых** узла 2 vCPU / 50 % / 8 ГБ / HDD 64 ГБ |
| Сеть | VPC, подсеть без публичных IP, NAT-шлюз, 3 группы безопасности, статический IP |
| Сетевые политики | **Calico** (`network_policy_provider = "CALICO"`) |
| Секреты K8s | шифруются ключом **KMS** |
| Реестр | Yandex Container Registry: образы + Helm-чарт как OCI, политика очистки |
| State | Object Storage, версионирование включено |
| Статика | картинки товаров в публичном бакете, загружаются Terraform'ом |
| Ingress | ingress-nginx на статическом IP |
| Мониторинг | kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics, node-exporter) |
| CI/CD | GitLab Практикума, общий instance-раннер, kaniko, crane, Helm |

## Ключевые решения и почему

| Решение | Альтернатива | Почему так |
|---|---|---|
| **Монорепозиторий** | отдельные репо для app / infra | один тег = состояние всего продукта, проще версионировать |
| **GitHub Flow** | Git Flow | одно prod-окружение; `develop`/`release/*` только удлиняют путь до прода |
| **SemVer из git-тега** `vX.Y.Z` | `1.0.${CI_PIPELINE_ID}` (как в репо 2022) | версия осмысленная и одна на все артефакты релиза |
| **Build once**: `crane tag :<sha> → :X.Y.Z` | пересборка на релизе | в прод идёт ровно тот образ, что прошёл тесты |
| **Managed Kubernetes** | k3s/kubeadm на ВМ | прямо указано в рекомендациях задания; не надо поддерживать control plane |
| **Зональный мастер** | региональный | в разы дешевле, отказоустойчивость мастера в учебном проекте не нужна |
| **Прерываемые узлы** + DaemonSet | обычные ВМ | рекомендация задания, экономия гранта |
| **2 узла, без автомасштабирования** | 2–3 узла | стартовые квоты облака; третий узел требует ещё квот |
| **kaniko** | docker-in-docker | не нужен privileged-раннер |
| **nginx фронтенда как шлюз к API** | Ingress прямо в backend | позволило переписать ссылки на картинки без изменения кода backend; backend недоступен даже из ingress |
| **Свой Helm-чарт** (umbrella) | чужой универсальный чарт | понимаю каждую строку; на защите это важно |
| **Свои Terraform-модули** | модули Yandex Cloud | то же: небольшие, понятные, с комментариями |
| **Платформа отдельно** от чарта приложения | всё в одном чарте (как в репо 2022) | деплой приложения не передеплоивает Prometheus и ingress |

## Структура репозитория

```
momo-store/
├── backend/                         # Go — исходники НЕ менялись
│   ├── Dockerfile                   # multi-stage → distroless, ~20 МБ
│   └── .dockerignore
├── frontend/                        # Vue — исходники НЕ менялись
│   ├── Dockerfile                   # multi-stage → nginx-unprivileged
│   ├── .dockerignore
│   └── nginx/{default.conf,common.inc}
├── infrastructure/
│   ├── .gitignore                   # tfstate, tfvars, ключи (корневой .gitignore не трогаем)
│   ├── terraform/
│   │   ├── .terraformrc             # зеркало провайдеров Yandex Cloud
│   │   ├── bootstrap/               # SA terraform + бакет для state
│   │   ├── envs/prod/               # основная инфраструктура
│   │   └── modules/{network,kubernetes,registry,storage}/
│   ├── helm/
│   │   ├── momo-store/              # umbrella: charts/backend, charts/frontend, ingress, netpol, дашборд
│   │   └── values-prod.yaml
│   ├── k8s-addons/                  # install.sh, values платформы, preemptible-handler, доступ CI
│   └── static/images/               # 8 картинок товаров → бакет
├── ci/                              # части пайплайна + скрипты
│   ├── templates.yml backend.yml frontend.yml infra.yml release.yml deploy.yml notify.yml
│   └── scripts/{release-notes,create-release,smoke-test,telegram}.sh
├── .gitlab-ci.yml
└── README.md
```

## Ветвление и версионирование

* `master` защищён: прямой push запрещён, только MR с зелёным пайплайном.
* Работа — в коротких ветках `feature/*`, `fix/*`.
* Релиз — **аннотированный тег** `vX.Y.Z` на `master` (теги `v*` защищены).

| Событие | Образы | Чарт | Деплой |
|---|---|---|---|
| push в ветку / MR | `:<short-sha>` (8 символов) | — | — |
| тег `v0.1.0` | `:<sha>` → `:0.1.0` | `momo-store-0.1.0` (OCI) | production |

```bash
git switch master && git pull
git tag -a v0.1.0 -m "Momo Store 0.1.0"
git push origin v0.1.0
```

Тег `latest` не используется. В реестре настроена очистка: untagged через 48 ч,
из SHA-сборок хранятся последние 20, SemVer-теги не удаляются.

## Хронология

| Этап | Что сделано |
|---|---|
| План | разбор задания, выбор архитектуры, разбор чужого репо 2022 года (что устарело) |
| Код | Terraform, Dockerfile'ы, Helm, платформа, CI, README — с локальной проверкой (`validate`, `helm lint`, kubeconform, hadolint, тесты в Docker) |
| Откат правок кода | исходники вернул как были, переделал решение через nginx и Helm |
| Облако | `yc init`, bootstrap → **AccessDenied** (не было биллинга) → привязка платёжного аккаунта |
| Инфраструктура | `terraform apply` 38 ресурсов → узлы зависли из-за **квот** → подняли квоты → узлы поднялись |
| Платформа | `install.sh`: Prometheus, Grafana, ingress-nginx, обработчик прерываний, доступ CI |
| GitLab | включил CI/CD в форке, нашёл раннер, завёл переменные |
| Пайплайн | упал trivy (запятые в JSON-ключе), затем — реальные CVE в базовых образах → исправил |
| Релиз | MR → merge → тег `v0.1.0` → release + deploy, приложение доступно |
| Доводка | метрики ingress (`metrics-per-host`), Grafana OOM → лимит 512Mi |
| Звёздочки | почта/Telegram, zero-trust, нагрузочный тест HPA, релизы `v0.1.1`–`v0.1.4`: автооткат, topologySpread, `scratch` |

## Статус чек-листа

**Основной:**

- [x] Приложение доступно из интернета по IPv4 (`http://<ingress_ip>/momo-store/`)
- [x] Конвейер проходит все этапы (build → test → release → deploy)
- [x] Артефакты версионированы по SemVer
- [x] Образы в Container Registry с версионными тегами
- [x] Инфраструктура соответствует коду (`terraform plan` → `No changes`)
- [x] Приложение в кластере с проверками работоспособности (readiness/liveness)
- [x] Дашборд отображает метрики приложения
- [x] README содержит инструкции по развёртыванию

**Со звёздочкой** — все проверены вручную:

- [x] Деплой «сломанной» версии приводит к автоматическому возврату (`v0.1.2` → откат через 5 мин, 0 ошибок у пользователей)
- [x] Уведомления при успехе/неудаче — почта и Telegram (Telegram из российских ДЦ доходит нестабильно)
- [x] Release Notes с описанием, ссылками на MR и авторами
- [x] Стратегия масштабирования описана и проверена нагрузкой: ~1 844 RPS, 0 ошибок, HPA 2 → 5 → 2
- [x] Неразрешённые запросы блокируются — 5 проверок, в обе стороны

## Где что лежит (локально, вне git)

| Файл | Что это |
|---|---|
| `~/.config/yandex-cloud/momo-terraform-key.json` | ключ SA `terraform` (провайдер yandex) |
| `~/.config/yandex-cloud/momo-s3.env` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` для S3-backend |
| `~/.config/yandex-cloud/momo-ci-key.json` | ключ SA CI → переменная `YC_CI_KEY` |
| `~/.config/yandex-cloud/momo-kubeconfig-ci` | kubeconfig CI → переменная `KUBECONFIG` |
| `~/.config/yandex-cloud/momo-grafana-password` | пароль `admin` в Grafana |
| `infrastructure/terraform/*/terraform.tfvars`, `backend.hcl` | ID облака/каталога, имена бакетов (в `.gitignore`) |

Все файлы с правами `600`. Оба tfstate лежат в приватном бакете, локальных копий нет.

## Сколько это занимает

Ориентир для первого прохода такого объёма:

| | Джун | Мидл |
|---|---|---|
| Базовые требования | ~2,5–3,5 недели | ~4–6 дней |
| Звёздочки | +1–1,5 недели | +1,5–2 дня |
| Повторное развёртывание по готовому коду и README | 1–2 часа | 1–2 часа |

Код пишется не дольше всего — время съедает **окружение**: биллинг, квоты, выключенный CI/CD,
раннеры, CVE в базовых образах, старый `KUBECONFIG`. Всё это — в [журнале проблем](diploma-troubleshooting.md).
