# Makefile проекта MkDocsPracticum
#
# Запуск:  make <цель> [ПЕРЕМЕННАЯ=значение]
# Список целей с описанием:  make   (или make help)
#
# Разбор синтаксиса — docs/makefile.md

# ---------- Переменные ----------
# ?= — значение по умолчанию, можно переопределить: make serve PORT=9000
VENV   ?= venv
PORT   ?= 8000
# := — вычисляется один раз, сразу
PYTHON := $(VENV)/bin/python
MKDOCS := $(VENV)/bin/mkdocs
SITE   := site

# Цель, которая запускается по голому `make`
.DEFAULT_GOAL := help

# Эти цели — не файлы, а просто имена команд
.PHONY: help venv install serve build strict deploy clean clean-all insert

# ---------- Справка ----------
# Собирает строки вида `цель: ... ## описание` из этого файла
help: ## Показать список целей
	@echo "Использование: make <цель> [VAR=value]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

# ---------- Окружение ----------
# Настоящая файловая цель: выполняется, только если файла $(PYTHON) нет
$(PYTHON):
	python3 -m venv $(VENV)

venv: $(PYTHON) ## Создать виртуальное окружение (если его нет)

# Файл-метка: pip запускается заново, только если requirements.txt
# новее метки. `|` — order-only: venv нужен, но его дата не важна.
$(VENV)/.installed: requirements.txt | $(PYTHON)
	$(PYTHON) -m pip install -q -r requirements.txt
	@touch $@

install: $(VENV)/.installed ## Установить зависимости из requirements.txt

# ---------- Работа с сайтом ----------
serve: install ## Локальный сервер с автообновлением (PORT=8000)
	$(MKDOCS) serve -a 127.0.0.1:$(PORT)

build: install ## Собрать сайт в ./site
	$(MKDOCS) build -d $(SITE)

strict: install ## Собрать со --strict: битые ссылки и ошибки nav = провал
	$(MKDOCS) build --strict -d $(SITE)

deploy: strict ## Ручной деплой на GitHub Pages (обычно это делает CI)
	$(MKDOCS) gh-deploy --force

# ---------- Скрипты ----------
# make insert FILE=docs/k8s.md SECTION=scripts/sections/daemonset.md AFTER="### Job"
insert: install ## Вставить секцию: FILE=... SECTION=... AFTER="..." | BEFORE="..."
	@test -n "$(FILE)" && test -n "$(SECTION)" || \
		{ echo "Нужно: make insert FILE=docs/x.md SECTION=scripts/sections/y.md AFTER=\"якорь\""; exit 1; }
	$(PYTHON) scripts/mkdocs_insert.py $(FILE) --section $(SECTION) \
		$(if $(AFTER),--after "$(AFTER)") $(if $(BEFORE),--before "$(BEFORE)")

# ---------- Уборка ----------
clean: ## Удалить собранный сайт
	rm -rf $(SITE)

clean-all: clean ## Удалить сайт и venv (make install создаст заново)
	rm -rf $(VENV)
