# CD: шпаргалка топ-20

Быстрый справочник по Continuous Delivery/Deployment. Теория — [CD (теория)](cd.md), стратегии — [CD: стратегии деплоя](cd-strategies.md).

## Топ-15 ключевых понятий

| # | Понятие | Суть |
|---|---|---|
| 1 | CI | авт. сборка и тесты каждого коммита |
| 2 | Continuous Delivery | артефакт всегда готов, деплой в prod — кнопкой |
| 3 | Continuous Deployment | деплой в prod — **полностью автоматический** |
| 4 | Артефакт | результат сборки (jar, образ, чарт) |
| 5 | Container Registry | хранилище Docker-образов |
| 6 | Тег образа | версия образа (`1.2.3`, `sha-abc`) |
| 7 | Окружение | dev / staging / prod |
| 8 | Staging | окружение, максимально похожее на prod |
| 9 | Deploy | выкатка версии в окружение |
| 10 | Rollback | откат на предыдущую версию |
| 11 | Rolling update | замена реплик по очереди, без даунтайма |
| 12 | Blue-green | 2 окружения, мгновенное переключение трафика |
| 13 | Canary | выкатка на малый % трафика с постепенным ростом |
| 14 | Smoke-тест | быстрая проверка после деплоя |
| 15 | GitOps | желаемое состояние в git, автоsync (ArgoCD/Flux) |

## Стратегии деплоя (сравнение)

| Стратегия | Даунтайм | Откат | Риск | Ресурсы |
|---|---|---|---|---|
| Recreate | ✅ есть | медленный | средний | низкие |
| Rolling | ❌ нет | медленный | средний | низкие |
| Blue-green | ❌ нет | **мгновенный** | низкий | **высокие** |
| Canary | ❌ нет | быстрый | **низкий** | средние |

## Шпаргалка выбора

```bash
# Нужен мгновенный откат и есть ресурсы?
→ Blue-green

# Хочется проверить на малой доле с контролем?
→ Canary

# Обычный сервис, доступность важна?
→ Rolling (K8s дефолт)

# Внутренний сервис, даунтайм неважен?
→ Recreate
```

## Пайплайн CD (мини)

```
build → test → package(registry) → deploy(staging) → e2e → approve → deploy(prod) → smoke
```

## Мини-пример (GitLab CI: staging + manual prod)

```yaml
stages: [build, test, deploy-staging, deploy-prod]

build:
  stage: build
  script: [docker build -t $REGISTRY/app:$CI_COMMIT_SHA .]
  only: [main]

deploy-staging:
  stage: deploy-staging
  script: [./deploy.sh staging]
  environment: staging
  only: [main]

deploy-prod:
  stage: deploy-prod
  script: [./deploy.sh prod]
  environment: production
  when: manual        # Continuous Delivery — кнопка
  only: [main]
```

## Правила CD (best practices)

- **Immutable-теги образов** (`sha`, версия) — никогда не перезаписывать `latest`.
- **Staging ≈ Prod** — одинаковый способ деплоя и конфиги.
- **План отката** — всегда знай, как вернуться назад.
- **Малые частые релизы** — проще откатывать.
- **Smoke-теста** после деплоя — сразу узнать, что сломалось.
- **Continuous Deployment** только когда есть хорошие автотесты и мониторинг, иначе рискуешь.

## Термины GitOps (топ-5)

| Инструмент | Роль |
|---|---|
| Argo CD | GitOps для Kubernetes |
| Flux | GitOps для Kubernetes |
| Helm | упаковка/шаблоны K8s-приложений |
| Registry | хранилище образов/чартов |
| Environment/Approve | окружения и ручные триггеры в CI |

> Полное описание стратегий — [CD: стратегии деплоя](cd-strategies.md).
