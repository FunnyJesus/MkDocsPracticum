# Python scripts

> Мини-шпаргалка конструкций: [Python: шпаргалка топ-20](python-cheatsheet.md).

Python — хорошая замена bash, когда скрипт начинает обрастать логикой: парсинг
JSON/YAML, HTTP-запросы, работа с каталогами, обработка ошибок. Bash отлично
справляется с «склеиванием команд», но как только нужно вложенное ветвление,
структуры данных и нормальный вывод в лог — python удобнее.

Этот раздел — не туториал по языку, а **набор готовых конструкций** под
повседневные DevOps-задачи, по аналогии с разделом Bash.

## Каркас скрипта

Минимальный «правильный» скрипт на python выглядит так:

```python
#!/usr/bin/env python3
"""Короткое описание того, что делает скрипт."""

import sys


def main() -> int:
    # ... логика ...
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Что здесь важно:

* `#!/usr/bin/env python3` — **shebang** (как в bash), позволяет запускать
  `./script.py` после `chmod +x`.
* `def main()` — логика вынесена в функцию. Так проще тестировать и переиспользовать.
* `if __name__ == "__main__":` — код выполнится, только если скрипт запущен
  напрямую, а не импортирован из другого файла.
* `raise SystemExit(main())` — аналог `exit` в bash: возвращает код завершения
  (0 = успех). Можно вернуть `1`, чтобы пометить ошибку — это подхватят CI
  (`&&`, `||`, пайплайны, Docker HEALTHCHECK).

> Аналог `set -euo pipefail`: в python нет флагов, вместо этого **явно
> обрабатываем ошибки** (`try/except`) и возвращаем ненулевой код через
> `SystemExit`. Если исключение не поймать — скрипт упадёт с traceback
> и кодом возврата 1.


## Виртуальное окружение (venv) — зачем нужно

Python ставит сторонние пакеты (`pip install`) не «в файл», а в каталог
`site-packages`, и ищет их там через `sys.path`. Если ставить всё глобально —
разные проекты начнут конфликтовать по версиям библиотек. **Виртуальное
окружение (venv)** изолирует набор пакетов для конкретного проекта.

Создать и активировать:
```bash
$ python3 -m venv .venv          # создать окружение в каталоге .venv
$ source .venv/bin/activate      # активировать (в bash)
```

После активации `pip install` ставится в `.venv`, а `python` берётся из него.

> **Важно.** Активация (`source`) нужна только чтобы пакеты из venv стали
> видны в текущем терминале. Она **не обязательна**, если вызывать
> интерпретатор по полному пути:

```bash
$ .venv/bin/python script.py     # работает без source
```

### Автоматический запуск из venv (обёртка)

В CI, cron и systemd нельзя полагаться на `source` — окружение там не
активировано. Вместо этого зовут интерпретатор по явному пути. Чтобы не
думать об этом каждый раз, в репозитории есть обёртка
[`scripts/run-python.sh`](https://github.com/FunnyJesus/MkDocsPracticum/blob/main/scripts/run-python.sh)
— она сама использует нужный `.venv` (и создаёт его + ставит зависимости,
если его ещё нет):

```bash
$ ./scripts/run-python.sh my_script.py --arg1 value
```

Так скрипт с `requests`/`yaml` одинаково работает локально, в CI и на сервере.

## Аргументы командной строки

### Быстрый вариант — `sys.argv`

`sys.argv` — список аргументов (как `$0`, `$1`, `$@` в bash):

```python
#!/usr/bin/env python3
import sys

script = sys.argv[0]        # имя скрипта (как $0)
args = sys.argv[1:]         # все аргументы (как $@)

if len(args) < 1:
    print("Использование: script.py FILE")
    sys.exit(1)             # ненулевой код при неверном вызове

print(f"Обрабатываю: {args[0]}")
```

### Правильный вариант — `argparse`

Для серьёзных скриптов лучше `argparse` — он сам генерирует `--help`,
сообщает о MissingArgumentError и умеет флаги:

```python
#!/usr/bin/env python3
import argparse


def main() -> int:
    p = argparse.ArgumentParser(description="Пример утилиты")
    p.add_argument("file", help="путь к файлу")              # позиционный
    p.add_argument("--verbose", action="store_true",         # флаг -v
                   help="подробный вывод")
    p.add_argument("--retries", type=int, default=3,         # с дефолтом
                   help="число попыток (по умолчанию 3)")
    args = p.parse_args()

    print(f"Файл: {args.file}, verbose={args.verbose}, retries={args.retries}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Запуск:
```bash
$ python3 script.py config.yaml --verbose
$ python3 script.py --help     # argparse сам покажет справку
```

## Работа с файлами и каталогами — `pathlib`

`pathlib.Path` — современный и удобный способ вместо `os.path`. Покрывает
большинство операций, которые в bash делаются через `ls`, `cp`, `mkdir`, `find`.

```python
#!/usr/bin/env python3
from pathlib import Path

p = Path("docs") / "k8s.md"      # собираем путь (как docs/k8s.md)
print(p.exists())                 # существует ли (как test -f)
print(p.is_file(), p.is_dir())    # файл или каталог
print(p.parent, p.name)           # родитель и имя (как dirname/basename)

# Создать каталог рекурсивно (аналог mkdir -p)
Path("logs/2026/09").mkdir(parents=True, exist_ok=True)

# Прочитать файл целиком
content = Path("app.conf").read_text(encoding="utf-8")

# Записать / дописать
Path("out.txt").write_text("hello\n", encoding="utf-8")
Path("log.txt").write_text("line\n", encoding="utf-8", mode="a")

# Обойти каталог (аналог find)
for f in sorted(Path("docs").glob("*.md")):
    print(f)
```

## Запуск команд — `subprocess` (аналог `$()`, пайпов)

Главный инструмент, когда нужен python, но хочется вызвать внешнюю команду —
ровно как `$(command)` или `command | command` в bash.

```python
#!/usr/bin/env python3
import subprocess

# Запустить и получить вывод (аналог $(command))
out = subprocess.run(
    ["kubectl", "get", "pods"],
    capture_output=True, text=True, check=False,
)
print(out.stdout)      # stdout
print(out.stderr)      # stderr
print(out.returncode)  # код возврата (аналог $?)
```

Советы:

* `text=True` — интерпретировать вывод как строку (иначе байты).
* `check=False` — **не** падать при ненулевом коде. Если `check=True`, то при
  ошибке поднимется исключение `CalledProcessError` — это аналог `set -e`.
* список аргументов (`["kubectl", "get", ...]`) — рекомендуемый способ, не
  строкой: не нужно беспокоиться о кавычках и спецсимволах (в отличие от `subprocess.shell=True`).
* предпочитай `subprocess.run()` (современный) вместо старого
  `subprocess.call()` / `subprocess.check_output()`.

## Переменные окружения — `os.environ`

Аналог `export VAR` / `$VAR`:

```python
#!/usr/bin/env python3
import os

token = os.environ.get("API_TOKEN")     # как ${API_TOKEN:-} — или None
if not token:
    raise SystemExit("Нет API_TOKEN в окружении")

os.environ.setdefault("LOG_LEVEL", "INFO")   # установить, если не задан
```

> Так скрипт не хранит секреты в коде — их передают через окружение
> (в CI, docker-compose `environment:`, systemd `Environment=`).

## Конфиги и данные — `json` и `yaml`

Парсинг структурных данных (вместо грепания текста).

```python
#!/usr/bin/env python3
import json

# JSON-строку → dict
data = json.loads('{"name": "app", "replicas": 3}')
# dict → JSON-строка (с красивым форматированием)
print(json.dumps(data, indent=2, ensure_ascii=False))

# JSON-файл → dict
with open("config.json", encoding="utf-8") as f:
    cfg = json.load(f)
```

YAML требует сторонней библиотеки `PyYAML` (`pip install pyyaml`):

```python
#!/usr/bin/env python3
import yaml

with open("values.yaml", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)      # всегда используй safe_load, не load

print(cfg.get("image", {}).get("tag"))
```

## HTTP-запросы — `requests` (аналог `curl`)

`requests` — стандарт для работы с API.

```python
#!/usr/bin/env python3
import requests

resp = requests.get("https://api.example.com/health",
                    headers={"Authorization": "Bearer TOKEN"},
                    timeout=10)          # всегда ставь timeout!
resp.raise_for_status()                  # упадёт, если статус 4xx/5xx
print(resp.status_code)
print(resp.json())                       # распарсить JSON-ответ

# POST с JSON-телом
resp = requests.post("https://api.example.com/deploy",
                     json={"ref": "main"}, timeout=30)
```

Паттерн для API:
```python
def api_get(path: str) -> dict:
    resp = requests.get(BASE + path, headers=HEADERS, timeout=10)
    resp.raise_for_status()
    return resp.json()
```

## Логирование — `logging` (вместо `echo`)

Печатать в `print` просто, но `logging` даёт уровни, время и направление в файл.

```python
#!/usr/bin/env python3
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

log.debug("отладка (не видна на INFO)")   # для себя
log.info("Начинаю работу")
log.warning("Порт занят, пробую следующий")
log.error("Не удалось получить ответ от API")
```

## Разбор ошибок

```python
try:
    data = api_get("/pods")
except requests.HTTPError as e:
    log.error(f"API вернул ошибку: {e}")
    raise SystemExit(1)     # ненулевой код — CI поймёт, что упало
```

## Реальный пример: утилита из команды

Собираем всё вместе — типичный «скрипт-утилита», который читает YAML-конфиг,
делает HTTP-запрос и логирует. Такой же паттерн используется в проекте
(например, `scripts/mkdocs_insert.py` — та же структура: `main()`,
`argparse`, `__name__ == "__main__"`).

```python
#!/usr/bin/env python3
"""Проверка здоровья сервисов из конфига через HTTP."""
import argparse
import logging
import sys
from pathlib import Path

import requests
import yaml

log = logging.getLogger(__name__)


def load_config(path: str) -> dict:
    """Читает YAML и отдаёт словарь (с понятной ошибкой, если файла нет)."""
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"Конфиг не найден: {path}")
    with p.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def check_service(url: str, timeout: int) -> bool:
    """Возвращает True, если сервис ответил 2xx."""
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
        return True
    except requests.RequestException as e:
        log.warning("%s недоступен: %s", url, e)
        return False


def main() -> int:
    p = argparse.ArgumentParser(description="Проверка здоровья сервисов")
    p.add_argument("config", help="путь к YAML-конфигу")
    p.add_argument("--timeout", type=int, default=5)
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    cfg = load_config(args.config)
    services = cfg.get("services", [])
    if not services:
        log.error("В конфиге нет списка services")
        return 1

    failed = 0
    for s in services:
        url = s["url"]
        ok = check_service(url, args.timeout)
        log.info("%-30s %s", url, "OK" if ok else "FAIL")
        failed += 0 if ok else 1

    if failed:
        log.error("Упавших сервисов: %d", failed)
        return 1
    log.info("Все сервисы доступны")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Пример конфига `services.yaml`:

```yaml
services:
  - url: https://api.example.com/health
  - url: https://auth.example.com/health
```

Запуск:
```bash
$ python3 healthcheck.py services.yaml
2026-09-10 12:00:01 INFO https://api.example.com/health OK
2026-09-10 12:00:02 INFO https://auth.example.com/health OK
2026-09-10 12:00:02 INFO Все сервисы доступны
```
