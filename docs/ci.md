# CI 

> Мини-шпаргалка конструкций: [CI: шпаргалка топ-20](ci-cheatsheet.md).


CI - не прерывная интеграция рабочих копий в основную ветку. При там подходе можно автоматизировать проверку каждого коммита до слияния

> Описывается в .yml в корне репозитория. Файл может имет дефолтное имя или нет, но при этом нужно явно указывать в настройка репозитория

> Самые популярные CI-серверы GitHub Actions, GitLab CI, Jenkins

## Словарик

### Pipeline
* Pipeline (от англ. pipeline — «трубопровод», «конвейер») - четко определенная последовательность этапов или процессов

---------

### Stage
* Stage - этап, на котором логически объеденены группы задач(Jobs)

---------

### Jobs
* Jobs - выполняемая задача

---------

## Пример Ci

```
stages:
  - lint
  - build
  - test

lint_code:
  stage: lint
  script:
    - npm run lint

build_app:
  stage: build
  script:
    - npm run build

unit_tests:
  stage: test
  script:
    - npm run test
```

### Описание примера 

```
stages:
  - lint
  - build
  - test
```

В блоке `stages` указаны этапы `pipeline`, они будут выполнятьс в том порядке, котором указаны. В данном примере 3 этапа

```
lint_code:
  stage: lint
  script:
    - npm run lint
```
Джоба `Jobs`

* Первая строка имя джобы
* Вторая строка указывает, на каком этапе будет выполняться джоба
* Треться строка, объявлен блок скриптов
* Четвертая строка выполняемые скрипты: установка библиотек, запуск кода, выполнение bash-скриптов


### runner (исполнитель)
* `runner` - агент (виртуальная машина или контейнер), на котором выполняется джоба. GitLab разрешает указывать, где запускать.

```
test:
  script:
    - pytest
  tags:
    - docker     # выполнять только на раннерах с тегом docker
```

### variables (переменные)
* `variables` - объявление переменных окружения, доступных джобам

```
variables:
  APP_ENV: "production"
  REGISTRY: "registry.example.com"

build:
  script:
    - echo "Деплой в $APP_ENV"    # использование переменной
    - docker build -t $REGISTRY/app .
```

> Переменные можно объявлять глобально (для всех джоб) и в отдельной джобе. Секреты (пароли, токены) хранят в CI/CD Settings, а не в файле.

### artifacts (артефакты)
* `artifacts` - файлы, сохраняемые после выполнения джобы (сборки, тест-отчёты), доступные между джобами или для скачивания

```
build:
  script:
    - npm run build
  artifacts:
    paths:
      - dist/            # сохранить каталог dist
    expire_in: 1 week    # время хранения
```

### only / rules (условия запуска)
* `only` - запускать джобу только при определённых условиях (ветка, тег)
* `rules` - более гибкие правила (условия, когда пропустить)

```
deploy:
  script:
    - deploy.sh
  only:
    - main           # запускать только на ветке main
    - tags           # и на тегах

# расширенный вариант через rules
deploy:
  script:
    - deploy.sh
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual      # запускать вручную (кнопкой)
```

### allow_failure / when
* `allow_failure` - не считает падение джобы провалом пайплайна (флаг `true`)
* `when` - когда запускать джобу: always, manual, on_success, on_failure, delayed

```
test_flaky:
  script:
    - pytest -m flaky
  allow_failure: true     # упавшая джоба не сломает пайплайн

deploy:
  script:
    - deploy.sh
  when: manual            # только вручную
```

### cache (кэш)
* `cache` - кэширование зависимостей (node_modules и т.п.) между прогонами для ускорения

```
build:
  script:
    - npm ci
  cache:
    key: "$CI_COMMIT_REF_SLUG"
    paths:
      - node_modules/
```

### GitLab CI vs GitHub Actions (быстрое сравнение)

| Понятие | GitLab CI | GitHub Actions |
|---------|-----------|----------------|
| Файл | `.gitlab-ci.yml` | `.github/workflows/*.yml` |
| Этап | `stage` | `job.<name>.runs-on` / `needs` |
| Задача | `job` + `script` | `job` + `steps` |
| Раннер/хост | `runner` (tags) | `runs-on` (ubuntu-latest, self-hosted) |
| Условия | `only` / `rules` | `if:` |
| Артефакты | `artifacts.paths` | `actions/upload-artifact` |
| Переменные секреты | CI/CD Settings | Settings → Secrets |

> Пример GitHub Actions:
> ```
> name: CI
> on: [push]
> jobs:
>   build:
>     runs-on: ubuntu-latest
>     steps:
>       - uses: actions/checkout@v4
>       - name: Установка зависимостей
>         run: npm ci
>       - name: Сборка
>         run: npm run build
> ```
