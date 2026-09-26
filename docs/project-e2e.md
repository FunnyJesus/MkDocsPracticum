# Сквозной проект: от кода до мониторинга

Один проект, который проходит **через весь стек** этого конспекта. Его можно сделать за несколько выходных, выложить на GitHub и показывать на собеседованиях как портфолио. Каждый этап — отдельная тема, которую ты уже изучил.

## Что строим

Небольшой веб-сервис **«shortener»** (сокращатель ссылок) на Python + PostgreSQL + Redis, который:

```
разработчик ─git push─► GitHub ──► CI: lint, test, scan, build ──► образ в GHCR
                                         │
                                         └─► обновляет тег в репо k8s-config
                                                        │
                    Argo CD (в кластере) ◄──следит──────┘
                          │
                          ▼
     Kubernetes: Gateway ─► shortener (Deployment, HPA) ─► PostgreSQL (оператор), Redis
                          │
                          ▼
     Prometheus + Grafana + Loki + Tempo — метрики, логи, трейсы, алерты
```

## Два репозитория

```
shortener/                        # код приложения
├── app/
│   ├── main.py                   # FastAPI: POST /links, GET /{code}, /health, /metrics
│   └── db.py
├── tests/
├── migrations/                   # Alembic
├── Dockerfile
├── Makefile
├── requirements.txt
└── .github/workflows/ci.yml

k8s-config/                       # что и как запущено (GitOps)
├── apps/shortener/
│   ├── base/                     # Deployment, Service, HPA, PDB, ServiceMonitor
│   └── overlays/{dev,prod}/
├── platform/                     # Gateway, cert-manager, мониторинг, CloudNativePG
└── argocd/
    ├── root.yaml                 # app-of-apps
    └── apps/*.yaml
```

## Этап 1. Приложение и Makefile

Минимальный сервис на FastAPI:

* `POST /links {"url": "..."}` → `{"code": "a1b2c3"}` (сохранить в PostgreSQL);
* `GET /{code}` → редирект 301 (кешировать в Redis);
* `GET /health` — liveness/readiness;
* `GET /metrics` — метрики Prometheus (`prometheus-fastapi-instrumentator`).

Все настройки — из переменных окружения (`DATABASE_URL`, `REDIS_URL`), по [12 factor](https://12factor.net/ru/).

```makefile
.PHONY: help install test lint run up down image
.DEFAULT_GOAL := help

help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*## "}; {printf "  %-8s %s\n", $$1, $$2}'
install: ## Зависимости
	pip install -r requirements.txt
lint: ## Линтеры
	ruff check . && hadolint Dockerfile
test: ## Тесты
	pytest -q
up: ## Поднять локально (app + postgres + redis)
	docker compose up -d --build
down: ## Остановить
	docker compose down
```

**Темы:** [Python](python-scripts.md), [Makefile](makefile.md), [Git](git.md).

## Этап 2. Docker и Compose

* Multi-stage Dockerfile, непривилегированный пользователь, `python:3.12-slim`, `HEALTHCHECK`.
* `docker-compose.yml`: app + postgres + redis, сеть, том для базы, `depends_on` с `condition: service_healthy`.

```dockerfile
FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
RUN useradd -r -u 10001 app
WORKDIR /app
COPY --from=build /install /usr/local
COPY app/ app/
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Готово, когда:** `make up` → `curl -X POST localhost:8000/links -d '{"url":"https://example.com"}'` работает.

**Темы:** [Docker](docker.md), [Docker Compose](docker-compose.md).

## Этап 3. CI

GitHub Actions на каждый push/PR:

1. `ruff`, `hadolint` — линтеры;
2. `pytest` с сервисным контейнером PostgreSQL;
3. `docker build` → `trivy image` (падать на CRITICAL);
4. push в `ghcr.io/<you>/shortener:<sha>`;
5. на `main` — обновить тег в `k8s-config/apps/shortener/overlays/dev` (`kustomize edit set image`) и закоммитить.

**Готово, когда:** push в main → через 5 минут новый тег в репо конфигурации.

**Темы:** [CI](ci.md), [Registry](registry.md), [Безопасность](security.md).

## Этап 4. Инфраструктура кодом

Вариант А (бесплатно, локально): кластер **kind** или **k3d** на ноутбуке.

```bash
kind create cluster --name lab --config kind.yaml     # 1 control-plane + 2 worker
```

Вариант Б (облако): **Terraform** создаёт сеть, managed Kubernetes и бакет для бэкапов; state — в remote backend с блокировкой.

Дополнительно — **Ansible**-плейбук, который готовит VM-бастион (пользователи, SSH-hardening, fail2ban).

**Темы:** [IaC](iac.md), [Terraform продвинутый](terraform-advanced.md), [Ansible](ansible.md), [Облака](cloud.md), [SSH](ssh.md).

## Этап 5. Kubernetes-манифесты

В `k8s-config/apps/shortener/base`:

* **Deployment**: 2 реплики, `requests/limits`, `readinessProbe`/`livenessProbe` на `/health`, `securityContext` (runAsNonRoot, readOnlyRootFilesystem);
* **Service** (ClusterIP);
* **HTTPRoute** на общий Gateway;
* **HPA** по CPU (2–6 реплик);
* **PodDisruptionBudget** (`minAvailable: 1`);
* **Job** миграций (Argo CD `PreSync` hook);
* **ExternalSecret** или **SealedSecret** для пароля БД.

Overlays: `dev` — 1 реплика, `prod` — 3 реплики и свои лимиты.

**Темы:** [Kubernetes](k8s.md), [Kustomize](kustomize.md) (или [Helm](helm.md) — [пример production-чарта](helm-podinfo.md)), [Gateway API](gateway-api.md), [Секреты](secrets.md).

## Этап 6. Платформа и GitOps

Через Argo CD (app-of-apps) ставится всё остальное:

| Компонент | Зачем |
|---|---|
| **Envoy Gateway** (или другой Gateway API контроллер) | вход в кластер |
| **cert-manager** | TLS-сертификаты (в kind — self-signed issuer) |
| **CloudNativePG** | PostgreSQL с репликой и бэкапами в S3/MinIO |
| **Redis** (Helm-чарт) | кеш |
| **kube-prometheus-stack** | Prometheus, Alertmanager, Grafana |
| **Loki** + **Tempo** + **OpenTelemetry Collector** | логи и трейсы |
| **Sealed Secrets** или **ESO + Vault** | секреты |

**Готово, когда:** удаляешь кластер, создаёшь заново, ставишь Argo CD + `root.yaml` → через 10 минут всё работает само. Это и есть проверка «инфраструктура как код».

**Темы:** [GitOps](gitops.md), [Базы данных](databases.md).

## Этап 7. Observability

* **ServiceMonitor** → Prometheus собирает `/metrics` приложения.
* **Дашборд Grafana**: RPS, доля 5xx, p95 латентности, cache hit Redis, соединения к БД — дашборд тоже в git (ConfigMap).
* **SLO**: 99.5% запросов `GET /{code}` быстрее 200 мс без 5xx; алерты по burn rate.
* **Логи** в JSON с `trace_id`, трейсы через OpenTelemetry autoinstrumentation.
* **Runbook** на каждый алерт — в репозитории, ссылка в аннотации алерта.

**Темы:** [Мониторинг](monitoring.md), [Трейсинг](tracing.md), [SRE](sre.md).

## Этап 8. Надёжность — ломаем специально

Проверь, что система ведёт себя, как ожидаешь, и опиши каждый эксперимент как мини-постмортем:

| Эксперимент | Ожидание |
|---|---|
| `kubectl delete pod` приложения | трафик не пропадает (2+ реплики, readiness) |
| Нагрузка `hey -z 2m -c 50 https://.../abc123` | HPA добавляет реплики |
| Выкатить образ с ошибкой на старте | readiness не проходит, старые поды продолжают работать |
| Удалить primary PostgreSQL | CloudNativePG переключает на реплику |
| Удалить namespace и восстановить из бэкапа (Velero / бэкап CNPG) | данные на месте, замерить RTO |
| Сломать DNS-имя базы в конфиге | алерт срабатывает, runbook помогает найти причину |

**Темы:** [Бэкапы и DR](backup-dr.md), [Типовые инциденты](incidents-practice.md).

## Что положить в README проекта

* Схему архитектуры (картинка или ASCII).
* «Как запустить за 5 команд» — `make` цели.
* Какие решения принял и **почему** (Kustomize или Helm, Argo CD или Flux, какой Gateway) — это то, о чём будут спрашивать.
* Скриншоты дашборда Grafana и Argo CD.
* Результаты экспериментов этапа 8.

## Чек-лист

- [ ] Приложение + тесты + Makefile
- [ ] Dockerfile (multi-stage, non-root) + docker-compose
- [ ] CI: lint → test → scan → build → push → обновление тега
- [ ] Кластер кодом (kind-конфиг или Terraform)
- [ ] Манифесты: probes, limits, HPA, PDB, securityContext
- [ ] Секреты не в открытом виде в git
- [ ] Argo CD + app-of-apps, кластер восстанавливается из git
- [ ] TLS через cert-manager
- [ ] Метрики, дашборд, SLO-алерты, runbook
- [ ] Логи и трейсы связаны через trace_id
- [ ] Бэкап базы и проверка восстановления
- [ ] Эксперименты с отказами описаны в README
