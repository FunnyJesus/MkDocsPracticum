# Обработка текста: grep, regex, sed, awk, jq, yq

DevOps постоянно работает с текстом: логи, вывод команд, конфиги, JSON из API, YAML-манифесты. Умение за одну строку вытащить нужное из гигабайтного лога — ежедневный навык.

> Мини-шпаргалка — [Обработка текста: шпаргалка](text-processing-cheatsheet.md). Основы конвейеров `|` — [Bash](bash-scripts.md).

## Философия: конвейер маленьких утилит

Каждая утилита делает одно дело, а `|` передаёт вывод следующей:

```bash
# топ-10 IP-адресов по числу запросов в логе nginx
cat access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -10
```

| Шаг | Что делает |
|---|---|
| `awk '{print $1}'` | взять первое поле строки (IP) |
| `sort` | отсортировать, чтобы одинаковые шли подряд |
| `uniq -c` | схлопнуть повторы и посчитать |
| `sort -rn` | сортировка по числу, по убыванию |
| `head -10` | первые 10 |

## Регулярные выражения

**Regex** — шаблон для поиска текста. Используется в `grep`, `sed`, `awk`, Python, Nginx, Prometheus, CI-правилах.

| Шаблон | Значит | Пример совпадения |
|---|---|---|
| `.` | любой один символ | `a.c` → `abc`, `a-c` |
| `*` | предыдущее 0 и больше раз | `ab*` → `a`, `abbb` |
| `+` | 1 и больше раз (ERE) | `ab+` → `ab`, `abbb` |
| `?` | 0 или 1 раз (ERE) | `https?` → `http`, `https` |
| `^` / `$` | начало / конец строки | `^ERROR` — строка начинается с ERROR |
| `[abc]` | один из символов | `[0-9]` — цифра |
| `[^abc]` | любой, кроме | `[^ ]+` — всё до пробела |
| `\|` или `|` (ERE) | или | `ERROR|FATAL` |
| `( )` | группа (ERE) | `(ab)+` |
| `{n,m}` | от n до m раз (ERE) | `[0-9]{1,3}` — 1–3 цифры |
| `\b` | граница слова | `\berror\b` не найдёт `errors` |
| `\d`, `\w`, `\s` | цифра, буква/цифра/_, пробельный (PCRE: `grep -P`) | `\d+` |

**BRE и ERE**: в базовом синтаксисе (`grep`, `sed`) символы `+ ? | ( ) {}` надо экранировать. Проще всегда использовать расширенный: **`grep -E`** и **`sed -E`**.

```bash
# IPv4-адрес (упрощённо)
grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' access.log
# HTTP-коды 5xx в логе nginx
grep -E '" 5[0-9]{2} ' access.log
```

## grep — найти строки

```bash
grep "error" app.log              # строки с error
grep -i "error" app.log           # без учёта регистра
grep -v "DEBUG" app.log           # все, КРОМЕ DEBUG
grep -c "error" app.log           # сколько строк
grep -n "error" app.log           # с номерами строк
grep -r "password" ./config       # рекурсивно по папке
grep -rl "TODO" src/              # только имена файлов
grep -E "ERROR|FATAL" app.log     # несколько шаблонов
grep -o -E "user_id=[0-9]+" app.log   # вывести только совпадение
grep -A 3 -B 2 "Exception" app.log    # 3 строки после и 2 до (контекст)
grep -w "fail" app.log            # целое слово
zgrep "error" app.log.1.gz        # поиск в сжатом логе
```

> Альтернатива для кода — `rg` (ripgrep): быстрее, сам учитывает `.gitignore`.

## sed — найти и заменить

```bash
sed 's/foo/bar/' file             # заменить первое вхождение в каждой строке (вывод на экран)
sed 's/foo/bar/g' file            # все вхождения
sed -i 's/foo/bar/g' file         # изменить файл на месте (Linux)
sed -i '' 's/foo/bar/g' file      # то же на macOS (BSD sed)
sed -i.bak 's/foo/bar/g' file     # с бэкапом file.bak (работает везде)
sed -n '10,20p' file              # вывести строки 10–20
sed '/^#/d' file                  # удалить строки-комментарии
sed '/^$/d' file                  # удалить пустые строки
sed -E 's/(v)[0-9.]+/\11.2.3/' file   # группа \1 в замене
sed 's|/old/path|/new/path|g' file    # другой разделитель, если в тексте есть /
```

Типичное в CI — подставить версию:

```bash
sed -i "s|image: myapp:.*|image: myapp:${CI_COMMIT_SHA}|" deploy.yaml
```

## awk — работа с колонками

`awk` делит строку на поля (по пробелам): `$1`, `$2`, … `$NF` — последнее, `NR` — номер строки.

```bash
awk '{print $1}' access.log                  # первая колонка
awk '{print $1, $9}' access.log              # IP и HTTP-код
awk -F: '{print $1}' /etc/passwd             # разделитель ':'
awk -F, 'NR > 1 {print $2}' data.csv         # пропустить заголовок CSV
awk '$9 >= 500' access.log                   # фильтр: только 5xx
awk '$9 == 404 {print $7}' access.log        # URL-ы с 404
awk '{sum += $10} END {print sum}' access.log        # сумма байт
awk '{sum += $NF} END {print sum/NR}' times.log       # среднее по последней колонке
awk '{count[$9]++} END {for (c in count) print c, count[c]}' access.log   # группировка
```

`cut` — проще, когда разделитель ровно один символ:

```bash
cut -d: -f1 /etc/passwd
cut -d, -f2,3 data.csv
```

## sort, uniq, wc, head, tail, xargs, tr

```bash
sort file | uniq                  # уникальные строки (uniq работает только с отсортированным!)
sort -u file                      # то же короче
sort -k2 -n file                  # по второй колонке как по числу
sort -t, -k3 -rn data.csv         # CSV по 3-й колонке, по убыванию
wc -l file                        # число строк
tail -f app.log                   # следить за логом
tail -n 100 app.log | head -20
tr 'a-z' 'A-Z' < file             # в верхний регистр
tr -d '\r' < win.txt > unix.txt   # убрать Windows-переводы строк
```

`xargs` — превратить строки в аргументы команды:

```bash
find . -name "*.log" -mtime +7 | xargs rm -f         # удалить логи старше 7 дней
find . -name "*.log" -print0 | xargs -0 rm -f        # безопасно для имён с пробелами
kubectl get pods -o name | grep old | xargs kubectl delete
cat hosts.txt | xargs -I{} ssh {} uptime             # {} — место подстановки
cat urls.txt | xargs -P 4 -n 1 curl -sO              # 4 параллельно
```

## jq — JSON

JSON отдают почти все API, `kubectl`, `aws`, `terraform output`, `docker inspect`.

```bash
echo '{"name":"app","replicas":3}' | jq '.'          # красиво отформатировать
jq '.name' file.json              # поле → "app"
jq -r '.name' file.json           # без кавычек → app (для скриптов)
jq '.items[0]' file.json          # первый элемент массива
jq '.items[].metadata.name'       # поле у каждого элемента
jq '.items | length'              # размер массива
jq '.items[] | select(.status == "failed")'          # фильтр
jq '.items[] | {name: .name, ip: .ip}'               # новая структура
jq -r '.items[] | "\(.name)\t\(.ip)"'                # в строку/TSV
jq '.replicas = 5' file.json      # изменить значение
jq -s '.' a.json b.json           # склеить в массив
```

Практика:

```bash
# имена подов не в статусе Running
kubectl get pods -o json | jq -r '.items[] | select(.status.phase != "Running") | .metadata.name'

# образы всех контейнеров в namespace
kubectl get pods -o json | jq -r '.items[].spec.containers[].image' | sort -u

# IP контейнера
docker inspect web | jq -r '.[0].NetworkSettings.Networks[].IPAddress'

# последний релиз на GitHub
curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name'

# output Terraform в переменную
DB_HOST=$(terraform output -json | jq -r '.db_host.value')
```

## yq — YAML

`yq` (версия Mike Farah, `brew install yq`) — как `jq`, но для YAML: манифесты K8s, values Helm, docker-compose, GitLab CI.

```bash
yq '.spec.replicas' deploy.yaml                   # прочитать
yq -i '.spec.replicas = 3' deploy.yaml            # изменить на месте
yq -i '.image.tag = "1.2.3"' values.yaml
TAG=abc123 yq -i '.image.tag = strenv(TAG)' values.yaml     # из переменной окружения
yq '.services | keys' docker-compose.yml          # список сервисов
yq -o json deploy.yaml                            # YAML → JSON
yq 'select(.kind == "Service")' all.yaml          # документ из многодокументного файла
```

> `yq` безопаснее `sed` для YAML: он понимает структуру и не сломает отступы.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `uniq` не убирает повторы | повторы идут не подряд | сначала `sort`, или `sort -u` |
| `sed -i` на macOS: `invalid command code` | BSD sed требует аргумент у `-i` | `sed -i '' ...` или `sed -i.bak ...` |
| `grep "a+b"` не находит `aab` | в BRE `+` — обычный символ | `grep -E "a+b"` |
| `jq` выдаёт строку в кавычках, скрипт ломается | нет `-r` | `jq -r` |
| `xargs rm` ломается на файлах с пробелами | разбивает по пробелам | `find -print0 | xargs -0` |
| `sed` сломал YAML/JSON | правка структуры как текста | `yq` / `jq` |

## Best Practices

* **`grep -E` и `sed -E` по умолчанию** — меньше экранирования, меньше ошибок.
* **Сначала без `-i`** — посмотреть результат `sed` на экране, потом менять файл.
* **Структурированные данные — структурными инструментами**: JSON → `jq`, YAML → `yq`.
* **`jq -r` в скриптах**, а вывод команд лучше запрашивать в JSON (`-o json`, `--format json`), чем парсить таблицы.
* **Длинный однострочник, который нужен повторно, — в скрипт** с комментарием.
