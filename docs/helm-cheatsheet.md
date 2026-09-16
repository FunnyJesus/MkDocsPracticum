# Helm: шпаргалка команд

Самое частое в работе с чартами: проверка, деплой, история, откат, разбор проблем.

> Теория — [Helm (теория)](helm.md). Объекты кластера, которые разворачивает чарт — [Kubernetes](k8s.md).

## Топ-20 команд

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | проверка | `helm lint ./chart` | линтер: структура чарта и типовые ошибки шаблонов |
| 2 | проверка | `helm template <release> ./chart` | отрендерить итоговые YAML локально, без кластера |
| 3 | проверка | `helm template ./chart -f values-prod.yaml` | рендер с values конкретного окружения |
| 4 | проверка | `helm upgrade --install <release> ./chart --dry-run --debug` | рендер + валидация на API-сервере |
| 5 | установка | `helm install <release> ./chart` | установить новый релиз |
| 6 | деплой | `helm upgrade --install <release> ./chart` | обновить релиз или установить, если его нет |
| 7 | деплой | `helm upgrade --install <release> ./chart --wait --timeout 5m --atomic` | безопасный деплой: ждать Ready, откатить при ошибке |
| 8 | values | `helm upgrade ... -f values-prod.yaml` | применить values-файл окружения |
| 9 | values | `helm upgrade ... --set image.tag=$CI_COMMIT_SHA` | переопределить одно значение (высший приоритет) |
| 10 | namespace | `helm upgrade ... -n production --create-namespace` | деплой в namespace, создать при отсутствии |
| 11 | обзор | `helm list` | релизы в текущем namespace |
| 12 | обзор | `helm list -A` | релизы во всех namespace |
| 13 | состояние | `helm status <release>` | статус релиза и содержимое NOTES.txt |
| 14 | история | `helm history <release>` | все ревизии релиза и их статусы |
| 15 | откат | `helm rollback <release> <revision>` | откатиться к ревизии (создаёт новую) |
| 16 | разбор | `helm get values <release>` | какие values реально применены |
| 17 | разбор | `helm get values <release> --all` | values вместе со значениями по умолчанию |
| 18 | разбор | `helm get manifest <release>` | какие манифесты Helm применил в кластер |
| 19 | удаление | `helm uninstall <release>` | удалить релиз и все его ресурсы |
| 20 | зависимости | `helm dependency update ./chart` | скачать зависимости чарта в `charts/` |

## Репозитории и готовые чарты

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo redis                  # найти чарт в подключённых репозиториях
helm show values bitnami/redis           # какие values поддерживает чужой чарт
helm install my-redis bitnami/redis -f my-values.yaml
```

## Компактные everyday-сценарии

```bash
# Проверить чарт перед деплоем (без кластера)
helm lint ./charts/my-app
helm template my-app ./charts/my-app -f ./charts/my-app/values-prod.yaml | less

# Деплой в прод из CI
helm upgrade --install my-app ./charts/my-app \
  -n production --create-namespace \
  -f ./charts/my-app/values-prod.yaml \
  --set image.tag=$CI_COMMIT_SHA \
  --wait --timeout 5m --atomic

# Посмотреть, что стоит и что применено
helm list -n production
helm history my-app -n production
helm get values my-app -n production

# Откат, если версия оказалась плохой
helm history my-app -n production
helm rollback my-app 3 -n production
helm status my-app -n production
```

## Разбор проблем

```bash
# Релиз завис в pending-upgrade (предыдущий деплой прервали)
helm history my-app
helm rollback my-app <последняя рабочая ревизия>

# В кластере не то, что ожидали
helm get values my-app        # с какими values собран релиз
helm get manifest my-app      # что реально применено
kubectl get pods,deploy,svc   # и что из этого живо

# Ошибка отступов при рендере
helm template ./chart | head -60   # смотреть отрендеренный YAML глазами
```

## Быстрая навигация

- **Проверка**: `helm lint`, `helm template`, `--dry-run --debug`
- **Деплой**: `helm upgrade --install ... --wait --timeout --atomic`
- **Окружения**: `-f values-<env>.yaml`, `--set key=value`
- **История и откат**: `helm history`, `helm rollback`, `helm status`
- **Разбор**: `helm get values`, `helm get manifest`, `helm list -A`
- **Зависимости**: `helm repo add/update`, `helm search repo`, `helm dependency update`

> Подробный разбор шаблонов, values и жизненного цикла релиза — [Helm (теория)](helm.md).
> Сквозной пример install → upgrade → rollback на `hashicorp/http-echo` — [там же](helm.md#hashicorphttp-echo).
