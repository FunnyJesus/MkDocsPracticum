# Обработка текста: шпаргалка

Самое частое при разборе логов, JSON и YAML.

> Теория и примеры — [Обработка текста](text-processing.md).

## Топ-20

| # | Утилита | Команда | Что делает |
|---|---|---|---|
| 1 | grep | `grep -i "error" app.log` | строки с error без учёта регистра |
| 2 | grep | `grep -v "DEBUG" app.log` | все строки, кроме DEBUG |
| 3 | grep | `grep -E "ERROR|FATAL" app.log` | несколько шаблонов |
| 4 | grep | `grep -rn "password" ./config` | рекурсивно с номерами строк |
| 5 | grep | `grep -A3 -B2 "Exception" app.log` | совпадение с контекстом |
| 6 | grep | `grep -oE "id=[0-9]+" app.log` | вывести только совпавшую часть |
| 7 | sed | `sed 's/old/new/g' file` | заменить все вхождения (на экран) |
| 8 | sed | `sed -i.bak 's/old/new/g' file` | заменить в файле с бэкапом |
| 9 | sed | `sed -n '10,20p' file` | вывести строки 10–20 |
| 10 | sed | `sed '/^#/d; /^$/d' file` | убрать комментарии и пустые строки |
| 11 | awk | `awk '{print $1, $9}' access.log` | вывести колонки 1 и 9 |
| 12 | awk | `awk -F: '{print $1}' /etc/passwd` | задать разделитель |
| 13 | awk | `awk '$9 >= 500' access.log` | фильтр по значению колонки |
| 14 | awk | `awk '{s+=$10} END {print s}' file` | сумма по колонке |
| 15 | конвейер | `sort | uniq -c | sort -rn | head` | топ самых частых строк |
| 16 | xargs | `find . -name "*.log" -print0 | xargs -0 rm` | аргументы из потока |
| 17 | jq | `jq -r '.items[].metadata.name'` | поле у каждого элемента массива |
| 18 | jq | `jq '.items[] | select(.status=="failed")'` | фильтр объектов |
| 19 | yq | `yq '.spec.replicas' deploy.yaml` | прочитать значение из YAML |
| 20 | yq | `yq -i '.image.tag = "1.2.3"' values.yaml` | изменить YAML на месте |

## Регулярки: минимум

| Шаблон | Значит |
|---|---|
| `.` | любой символ |
| `*` / `+` / `?` | 0+, 1+, 0–1 раз |
| `^` / `$` | начало / конец строки |
| `[0-9]`, `[a-z]`, `[^ ]` | класс символов / отрицание |
| `{2,4}` | от 2 до 4 раз |
| `(a|b)` | группа, «или» |

## Готовые однострочники

```bash
# топ IP в логе nginx
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head

# сколько ответов каждого HTTP-кода
awk '{print $9}' access.log | sort | uniq -c | sort -rn

# ошибки за последний час из journald
journalctl --since "1 hour ago" -p err --no-pager

# поды не в Running
kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase!="Running") | "\(.metadata.namespace)/\(.metadata.name)"'

# подставить тег образа в values Helm в CI
yq -i ".image.tag = \"${CI_COMMIT_SHORT_SHA}\"" chart/values.yaml
```
