#!/usr/bin/env python3
"""Вставка markdown-секции в файл документации MkDocs по якорю.

Переиспользуемый инструмент: секции держим отдельными .md-файлами,
а этот скрипт вставляет их в целевой документ до или после якоря.
Полезен, когда в k8s.md, docker.md и т.п. нужно добавить новый подраздел
без ручного редактирования.

Пример:
    python3 scripts/mkdocs_insert.py docs/k8s.md \
        --section scripts/sections/cronjob.md \
        --after "### Job — одноразовые задачи"

    python3 scripts/mkdocs_insert.py docs/k8s.md \
        --section scripts/sections/daemonset.md \
        --before "### Метки и селекторы (labels / selectors)"
"""
import argparse
import io
import sys


def read_file(path: str) -> str:
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def write_file(path: str, content: str) -> None:
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(content)


def main() -> int:
    p = argparse.ArgumentParser(
        prog="mkdocs_insert.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("target", help="целевой файл документации, напр. docs/k8s.md")
    p.add_argument(
        "--section",
        required=True,
        help="путь к .md-файлу с новой секцией (вставляется как есть, оборачивается пустыми строками)",
    )
    p.add_argument(
        "--after",
        help="якорь (строка/заголовок), ПОСЛЕ которого вставить секцию",
    )
    p.add_argument(
        "--before",
        help="якорь (строка/заголовок), ПЕРЕД которым вставить секцию",
    )
    p.add_argument(
        "--dedupe-heading",
        help="заголовок секции; если он уже есть в файле — скрипт выйдет с ошибкой (защита от дублей). "
             "Обычно совпадает с первой строкой --section"
    )
    args = p.parse_args()

    if bool(args.after) == bool(args.before):
        p.error("нужно указать ровно один из --after / --before")

    text = read_file(args.target)
    section = read_file(args.section).strip()

    if args.dedupe_heading and args.dedupe_heading in text:
        sys.exit(f"Ошибка: в {args.target} уже есть '{args.dedupe_heading}'. "
                 f"Ничего не изменено (защита от дублей).")

    anchor = args.after or args.before
    if anchor not in text:
        sys.exit(f"Ошибка: якорь не найден в {args.target}: {anchor!r}\n"
                 f"Текст файла мог измениться — проверьте и поправьте якорь.")

    # Секция всегда отделяется двумя пустыми строками (пустая строка перед
    # заголовком обязательна для корректного рендера Markdown).
    section = section.strip("\n")
    section = "\n\n" + section + "\n"

    if args.after:
        text = text.replace(anchor, anchor + section, 1)
    else:
        text = text.replace(anchor, section + "\n" + anchor, 1)

    # Нормализуем: не больше двух пустых строк подряд, чтобы вставка не
    # накапливала лишние пробелы между соседними блоками.
    while "\n\n\n\n" in text:
        text = text.replace("\n\n\n\n", "\n\n\n")

    write_file(args.target, text)
    print(f"OK: секция из '{args.section}' вставлена в '{args.target}' "
          f"({'после' if args.after else 'перед'} якоря '{anchor}').")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
