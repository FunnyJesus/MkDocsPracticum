# Makefile

> Мини-шпаргалка: [Makefile: шпаргалка топ-20](makefile-cheatsheet.md).

## Что такое Make и зачем он DevOps-у

**Make** — утилита, которая выполняет команды по описанию из файла `Makefile`. Изначально её придумали для сборки программ на C: «перекомпилируй только те файлы, которые изменились». Сегодня в DevOps Makefile чаще всего используют как **единую точку входа в проект**:

```bash
make install   # поставить зависимости
make test      # прогнать тесты
make build     # собрать образ / сайт / бинарник
make deploy    # выкатить
```

Зачем это нужно:

* **Не надо помнить длинные команды.** `docker build -t registry/app:$(git rev-parse --short HEAD) --build-arg ...` превращается в `make image`.
* **Одинаково у всех.** Новый человек в команде делает `make` и видит список действий. CI вызывает те же `make test`, что и разработчик локально.
* **Зависимости между шагами.** `deploy` сам запустит `build`, а `build` — `install`.
* **Не делать лишнюю работу.** Если файл-результат новее исходников — шаг пропускается.

Make уже установлен в macOS (Xcode Command Line Tools) и в большинстве Linux-дистрибутивов (`apt install make`). Проверить: `make --version`.

## Анатомия правила

Makefile состоит из **правил** (rules):

```makefile
цель: зависимости
	команда 1
	команда 2
```

* **цель (target)** — имя, которое пишешь после `make`. Классически это имя файла, который нужно получить.
* **зависимости (prerequisites)** — что должно быть готово до выполнения цели: другие цели или файлы.
* **рецепт (recipe)** — shell-команды, которые выполняются для цели.

!!! warning "Самое важное правило"
    Строки рецепта начинаются с **TAB**, а не с пробелов. Иначе получишь ошибку `Makefile:3: *** missing separator.  Stop.`
    Настрой редактор: в VS Code справа внизу «Spaces: 4» → «Indent Using Tabs» для Makefile (обычно определяется автоматически).

Минимальный пример:

```makefile
hello:
	echo "Привет, Make!"
```

```bash
$ make hello
echo "Привет, Make!"      # make печатает команду перед выполнением
Привет, Make!
```

## Как Make решает, что запускать

Make смотрит на **время изменения файлов**:

1. Если файла с именем цели **нет** — рецепт выполняется.
2. Если файл есть, но **какая-то зависимость новее** — рецепт выполняется.
3. Иначе — `make: 'цель' is up to date.` / `Nothing to be done for 'цель'`.

```makefile
report.txt: data.csv
	wc -l data.csv > report.txt
```

```bash
$ make report.txt     # создаст report.txt
$ make report.txt     # make: 'report.txt' is up to date.
$ touch data.csv      # «обновили» исходник
$ make report.txt     # пересоберёт
```

Зависимости выполняются **до** цели, рекурсивно, и каждая — не больше одного раза за запуск:

```makefile
deploy: build
	echo "deploy"

build: install
	echo "build"

install:
	echo "install"
```

```bash
$ make deploy
install
build
deploy
```

## .PHONY — цели-команды

В DevOps большинство целей (`test`, `clean`, `deploy`) — **не файлы**, а просто команды. Если в папке случайно появится файл `clean`, Make решит, что цель «уже готова», и ничего не сделает. Чтобы этого не было, такие цели объявляют «фальшивыми»:

```makefile
.PHONY: install test build clean

clean:
	rm -rf site
```

Правило: **всё, что не создаёт файл с таким же именем, — в `.PHONY`.**

## Цель по умолчанию

Голый `make` запускает **первую цель в файле**. Поэтому первой обычно ставят `help` или `all`. Можно указать явно:

```makefile
.DEFAULT_GOAL := help
```

## Переменные

```makefile
IMAGE   := myapp          # := вычисляется сразу, один раз (используй по умолчанию)
TAG     ?= latest         # ?= задать, только если ещё не задано (извне/окружением)
FLAGS   += --verbose      # += дописать к существующему значению
LAZY     = $(shell date)  # =  вычисляется каждый раз при использовании

build:
	docker build -t $(IMAGE):$(TAG) .
```

Обращение — `$(VAR)` или `${VAR}`. Переопределение из командной строки:

```bash
make build TAG=1.2.3            # переменная из CLI перекрывает значения из Makefile
TAG=1.2.3 make build            # из окружения — сработает только для ?=
```

Полезные функции:

```makefile
GIT_SHA := $(shell git rev-parse --short HEAD)   # результат shell-команды
SRC     := $(wildcard docs/*.md)                 # список файлов по маске
$(if $(DEBUG),--verbose)                         # подставить, если DEBUG не пустой
```

### Автоматические переменные

Работают внутри рецепта:

| Переменная | Значение |
|---|---|
| `$@` | имя текущей цели |
| `$<` | первая зависимость |
| `$^` | все зависимости (без повторов) |

```makefile
report.txt: data.csv header.txt
	cat $^ > $@        # cat data.csv header.txt > report.txt
```

## Особенности рецептов

**Каждая строка — отдельный shell.** Поэтому `cd` «не держится»:

```makefile
bad:
	cd terraform
	terraform plan          # выполнится в корне проекта!

good:
	cd terraform && terraform plan
```

**Знак `$` нужно удваивать**, если он для shell, а не для Make:

```makefile
list:
	for f in *.md; do echo $$f; done
	echo "Мой HOME: $$HOME"
```

**Префиксы строк:**

```makefile
quiet:
	@echo "@ — не печатать саму команду, только её вывод"
	-rm file-that-may-not-exist    # - игнорировать ошибку и идти дальше
```

По умолчанию Make **останавливается на первой ошибке** (ненулевой код выхода) — как `set -e` в Bash.

**Перенос длинной строки** — обратный слеш `\`:

```makefile
up:
	docker run -d \
		-p 8080:80 \
		--name web nginx
```

## Самодокументирующийся help

Популярный приём: пишем описание после `##`, а цель `help` вытаскивает их grep-ом.

```makefile
.DEFAULT_GOAL := help

help: ## Показать список целей
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  %-12s %s\n", $$1, $$2}'

test: ## Прогнать тесты
	pytest
```

```bash
$ make
  help         Показать список целей
  test         Прогнать тесты
```

## Типичный Makefile DevOps-проекта

```makefile
IMAGE ?= registry.example.com/myapp
TAG   ?= $(shell git rev-parse --short HEAD)
ENV   ?= dev

.DEFAULT_GOAL := help
.PHONY: help lint test image push tf-plan tf-apply deploy

help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

lint: ## Линтеры
	hadolint Dockerfile
	helm lint ./chart

test: ## Тесты
	pytest -q

image: ## Собрать Docker-образ
	docker build -t $(IMAGE):$(TAG) .

push: image ## Отправить образ в registry
	docker push $(IMAGE):$(TAG)

tf-plan: ## terraform plan для ENV
	cd terraform/$(ENV) && terraform init -input=false && terraform plan

tf-apply: ## terraform apply для ENV
	cd terraform/$(ENV) && terraform apply

deploy: push ## Деплой через Helm
	helm upgrade --install myapp ./chart \
		-f chart/values-$(ENV).yaml \
		--set image.tag=$(TAG) \
		--wait --atomic
```

```bash
make deploy ENV=prod          # lint/test не вызваны — только push → image → deploy
make tf-plan ENV=staging
```

И в CI шаги становятся короткими:

```yaml
# GitHub Actions
- run: make lint test
- run: make deploy ENV=prod
```

## Makefile этого проекта

В корне репозитория лежит `Makefile` для работы с этой заметочной:

| Команда | Что делает |
|---|---|
| `make` / `make help` | список целей |
| `make install` | создать `venv/` (если нет) и поставить `requirements.txt` |
| `make serve` | локальный сервер на http://127.0.0.1:8000 с автообновлением |
| `make serve PORT=9000` | то же на другом порту |
| `make build` | собрать сайт в `site/` |
| `make strict` | собрать со `--strict` — упадёт на битых ссылках и ошибках nav |
| `make deploy` | ручной деплой на GitHub Pages (обычно это делает CI при push) |
| `make insert FILE=... SECTION=... AFTER="..."` | вставить секцию через `scripts/mkdocs_insert.py` |
| `make clean` | удалить `site/` |
| `make clean-all` | удалить `site/` и `venv/` |

Что в нём можно подсмотреть:

* **Файловая цель `$(PYTHON)`** — venv создаётся, только если нет `venv/bin/python`.
* **Файл-метка `venv/.installed`** зависит от `requirements.txt`. Поэтому `pip install` запускается, только когда ты поменял зависимости. Второй `make install` скажет `Nothing to be done`.
* **Order-only зависимость** `| $(PYTHON)` — venv должен существовать, но его дата изменения не заставляет переустанавливать пакеты.
* **Цепочка** `deploy → strict → install → venv` — достаточно вызвать последний шаг.

Пример вставки секции:

```bash
make insert FILE=docs/k8s.md \
    SECTION=scripts/sections/daemonset.md \
    BEFORE="### Метки и селекторы (labels / selectors)"
```

## Отладка

```bash
make -n deploy        # dry-run: показать команды, но не выполнять
make -B build         # принудительно пересобрать, игнорируя даты файлов
make -C subdir test   # запустить make в другой директории
make -j4              # выполнять независимые цели параллельно
make -p | less        # показать все правила и переменные (с встроенными)
```

## Частые ошибки

| Ошибка | Причина | Решение |
|---|---|---|
| `*** missing separator.  Stop.` | рецепт начинается с пробелов | заменить отступ на TAB |
| `Nothing to be done for 'test'` / `'test' is up to date` | существует файл с именем цели | добавить цель в `.PHONY` |
| `No rule to make target 'X'` | опечатка в имени цели или нет файла-зависимости | проверить имя и путь |
| `cd` «не сработал» | каждая строка — новый shell | `cd dir && команда` в одной строке |
| переменная shell пустая | `$VAR` съел Make | писать `$$VAR` |
| на macOS не работает `.ONESHELL`, `$(file ...)` | в macOS старый GNU Make 3.81 | `brew install make` → команда `gmake` |
