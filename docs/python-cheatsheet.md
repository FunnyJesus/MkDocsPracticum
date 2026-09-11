# Python: шпаргалка топ-20 конструкций

Самое нужное для написания скриптов на python DevOps-инженером, привыкшим к bash.

> Подробные примеры и объяснения — [Python scripts](python-scripts.md).

## Сопоставление bash → python

| Что делаю в bash | Как в python |
|---|---|
| `#!/usr/bin/env bash`, `set -euo pipefail` | `#!/usr/bin/env python3` + `if __name__ == "__main__":` и `raise SystemExit(main())` |
| `$1`, `$@` | `sys.argv[1]`, `sys.argv[1:]` или `argparse` |
| `echo`, `printf` | `print()` |
| `$(command)` | `subprocess.run([...], capture_output=True, text=True)` |
| `command \| grep \| sort` | `subprocess` + методы строк, `sorted()` |
| `VAR=value`, `export VAR` | `os.environ.get("VAR")` |
| `if [ -f f ]; then` | `Path(f).exists()`, `Path(f).is_file()` |
| `for i in list; do` | `for i in list:` |
| `ls`, `cp`, `mkdir -p` | `pathlib.Path` (`.glob`, `.read_text`, `.mkdir`) |
| `curl` | `requests.get/post` |
| `cat file \| grep` | `Path(file).read_text()` + `.splitlines()` |
| `$?` (код возврата) | `SystemExit(code)`, `subprocess.returncode` |
| `echo "$x" > file` | `Path(file).write_text(...)` |
| комментарии `#` | `#` или docstring `"""..."""` |
| `jq '.replicas'` | `json.loads(...)["replicas"]` |

## Топ-20 конструкций

| # | Конструкция | Что делает |
|---|---|---|
| 1 | `#!/usr/bin/env python3` | shebang — запуск через python3 |
| 2 | `if __name__ == "__main__":` | выполнить только при запуске напрямую |
| 3 | `raise SystemExit(main())` | вернуть код завершения (0 = успех) |
| 4 | `sys.argv[1:]` | аргументы командной строки |
| 5 | `argparse` + `add_argument` | разбор аргументов с `--help` |
| 6 | `from pathlib import Path` | удобная работа с путями/файлами |
| 7 | `Path(p).exists()` | проверить, есть ли файл/каталог |
| 8 | `Path(p).read_text(encoding="utf-8")` | прочитать файл строкой |
| 9 | `Path(p).write_text(...)` | записать файл |
| 10 | `Path(p).mkdir(parents=True, exist_ok=True)` | аналог `mkdir -p` |
| 11 | `Path(p).glob("*.md")` | обойти файлы по маске (аналог `find`) |
| 12 | `subprocess.run([...], capture_output=True, text=True)` | запустить команду и получить вывод |
| 13 | `subprocess.run(..., check=True)` | падать при ошибке (аналог `set -e`) |
| 14 | `os.environ.get("VAR")` | прочитать переменную окружения |
| 15 | `json.loads` / `json.dumps` | распарсить / сериализовать JSON |
| 16 | `yaml.safe_load` | распарсить YAML (ставить `safe_load`!) |
| 17 | `requests.get(url, timeout=10)` | HTTP-запрос (аналог `curl`) |
| 18 | `resp.raise_for_status()` | упасть при HTTP-ошибке 4xx/5xx |
| 19 | `try: / except ...:` | обработка ошибок |
| 20 | `logging` + `basicConfig` | нормальный лог вместо `print` |

## Мини-шаблон скрипта

```python
#!/usr/bin/env python3
"""Описание скрипта."""
import argparse
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description="...")
    p.add_argument("file", help="путь к файлу")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    if not Path(args.file).exists():
        print(f"Нет файла: {args.file}")
        return 1

    print(f"Обрабатываю {args.file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```
