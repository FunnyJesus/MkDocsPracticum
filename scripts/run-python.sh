#!/usr/bin/env bash
# Запускает python-скрипт из виртуального окружения проекта.
# Работает одинаково на локальной машине и в CI (без ручного `source`).
#
# Использование:
#   ./scripts/run-python.sh myscript.py [аргументы]
#
# Если venv нет — создаёт его и ставит зависимости из requirements.txt.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${DIR}/.venv"
PY="${VENV}/bin/python"

if [ ! -x "$PY" ]; then
    echo "Создаю виртуальное окружение: $VENV"
    python3 -m venv "$VENV"
fi

if [ -f "${DIR}/requirements.txt" ]; then
    "$PY" -m pip install -q -r "${DIR}/requirements.txt"
fi

exec "$PY" "$@"
