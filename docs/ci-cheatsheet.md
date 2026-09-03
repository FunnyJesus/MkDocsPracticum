# CI: шпаргалка топ-20 конструкций

Быстрый справочник по GitLab CI и GitHub Actions. Теория (словарик, разбор примера) — на странице [CI (теория)](ci.md).

## Параллель: GitLab CI ↔ GitHub Actions

| Понятие | GitLab CI | GitHub Actions |
|---|---|---|
| Файл | `.gitlab-ci.yml` | `.github/workflows/*.yml` |
| Конвейер | `pipeline` | `workflow` |
| Этап | `stages` / `stage` | порядок `jobs` + `needs` |
| Задача | `job` + `script` | `job` + `steps` |
| Исполнитель | `runner` (tags) | `runs-on` |
| Условия | `only` / `rules` / `when` | `if:` |
| Артефакты | `artifacts.paths` | `actions/upload-artifact` |
| Кэш | `cache` | `actions/cache` |
| Секреты | CI/CD Settings | Settings → Secrets |

## Топ-20 конструкций (GitLab CI)

| # | Конструкция | Что делает |
|---|---|---|
| 1 | `stages: [lint, build, test]` | объявить этапы пайплайна (порядок важен) |
| 2 | `my_job:` | объявить джобу |
| 3 | `stage: build` | привязать джобу к этапу |
| 4 | `script: [cmd]` | команды, выполняемые в джобе |
| 5 | `variables: KEY: "val"` | переменные окружения (глобальные/локальные) |
| 6 | `tags: [docker]` | выбрать раннер по тегу |
| 7 | `artifacts.paths: [dist/]` | сохранить файлы между джобами |
| 8 | `artifacts.expire_in: 1 week` | срок хранения артефактов |
| 9 | `cache.key/paths` | кэш зависимостей между прогонами |
| 10 | `only: [main, tags]` | запускать только на ветке/тегах |
| 11 | `rules: - if: '$CI_COMMIT_BRANCH == "main"'` | гибкое условие запуска |
| 12 | `when: manual` | запуск вручную (кнопкой) |
| 13 | `when: on_success / on_failure / always` | когда запускать |
| 14 | `allow_failure: true` | падение не ломает пайплайн (flaky) |
| 15 | `image: node:20` | образ для раннера-контейнера |
| 16 | `services:` | доп. сервисы (БД, redis) |
| 17 | `only: - merge_requests` | только при MR |
| 18 | `#` | комментарии в YAML |
| 19 | `$CI_*` | встроенные переменные (`$CI_COMMIT_BRANCH`) |
| 20 | `extends: .base` | переиспользование общих конфигов |

## Топ-15 конструкций (GitHub Actions)

| # | Конструкция | Что делает |
|---|---|---|
| 1 | `name: CI` | имя workflow |
| 2 | `on: [push]` | триггеры (push / pull_request / schedule) |
| 3 | `jobs:` | объявить задачи |
| 4 | `runs-on: ubuntu-latest` | ОС/образ исполнителя |
| 5 | `steps:` | шаги задачи |
| 6 | `- uses: actions/checkout@v4` | клонировать репозиторий |
| 7 | `- uses: actions/setup-node@v4` | установить рантайм (node/python) |
| 8 | `- name: "Заголовок"` | название шага |
| 9 | `- run: npm ci` | команда шага |
| 10 | `with: node-version: '20'` | параметры действия (uses) |
| 11 | `env: KEY: val` | переменные окружения шага/джобы |
| 12 | `if: github.ref == 'refs/heads/main'` | условие выполнения |
| 13 | `needs: [build]` | зависимость от другой джобы |
| 14 | `secrets: MY_SECRET` | доступ к секрету |
| 15 | `${{ matrix.os }}` | матрица (тест на нескольких версиях) |

## Готовый шаблон GitLab CI

```yaml
stages:
  - lint
  - build
  - test
  - deploy

variables:
  APP_ENV: "production"

lint_code:
  stage: lint
  script:
    - npm run lint
  only:
    - main

build_app:
  stage: build
  script:
    - npm ci
    - npm run build
  artifacts:
    paths: [dist/]
    expire_in: 1 week
  cache:
    key: "$CI_COMMIT_REF_SLUG"
    paths: [node_modules/]

unit_tests:
  stage: test
  script: [npm run test]
  allow_failure: true

deploy:
  stage: deploy
  script: [deploy.sh]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
```

## Готовый шаблон GitHub Actions

```yaml
name: CI
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - name: Установка зависимостей
        run: npm ci
      - name: Сборка
        run: npm run build
      - name: Тесты
        run: npm run test
        env:
          APP_ENV: production

  deploy:
    runs-on: ubuntu-latest
    needs: [build]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Деплой
        run: ./deploy.sh
        env:
          TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

## Правила безопасности

- **Секреты (пароли, токены) НЕ класть в YAML** — хранить в CI/CD Settings (GitLab) / Settings → Secrets (GitHub).
- `when: manual` для деплоя — защита от случайного запуска.
- `allow_failure: true` — только для flaky-тестов, не для основных.
- Артефакты и кэш — не хранить в git.

> Теория и разбор конструкций — на странице [CI (теория)](ci.md).
