# Kubernetes: шпаргалка топ-20 команд

Самое частое в работе с кластером. Быстрые команды `kubectl` для обзора, деплоя, диагностики и отката.

> Подробно по каждой команде: [Kubernetes: команды с подробным описанием](k8s-commands.md). Теория — [Kubernetes (теория)](k8s.md).
> Удобный TUI-обозреватель вместо команд: [k9s — быстрая навигация по кластеру](k9s.md).

## Топ-20 команд

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | доступ | `kubectl config current-context` | текущий контекст |
| 2 | доступ | `kubectl config use-context <имя>` | переключить контекст |
| 3 | обзор | `kubectl get nodes` | список нод (проверка доступа) |
| 4 | обзор | `kubectl cluster-info` | адрес API-сервера |
| 5 | поды | `kubectl get pods` | список подов |
| 6 | поды | `kubectl get pods -A` | поды во всех namespace |
| 7 | поды | `kubectl get pods -o wide` | поды с IP и нодой |
| 8 | поды | `kubectl describe pod <имя>` | детали и события пода |
| 9 | логи | `kubectl logs <pod>` | логи пода |
| 10 | логи | `kubectl logs -f <pod>` | следить за логами |
| 11 | отладка | `kubectl exec -it <pod> -- sh` | зайти внутрь контейнера |
| 12 | отладка | `kubectl port-forward pod/<pod> 8080:80` | пробросить порт на под |
| 13 | деплой | `kubectl apply -f <файл>.yaml` | применить манифест |
| 14 | деплой | `kubectl get deploy` | список Deployment |
| 15 | масштаб | `kubectl scale deploy <имя> --replicas=N` | изменить число реплик |
| 16 | обновление | `kubectl set image deploy/<имя> app=nginx:1.28 --record` | сменить образ |
| 17 | откат | `kubectl rollout status deploy/<имя>` | статус выката |
| 18 | откат | `kubectl rollout undo deploy/<имя>` | откат к предыдущей версии |
| 19 | сеть | `kubectl get svc` | список Service |
| 20 | события | `kubectl get events` | события кластера (диагностика) |

## Компактные everyday-сценарии

```bash
# Обзор и проверка доступа
kubectl config current-context
kubectl get nodes
kubectl get pods -A

# Деплой из манифеста и проверка
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl get deploy,svc,pods
kubectl rollout status deployment/my-app

# Смотреть логи всех реплик деплоймента
kubectl logs deployment/my-app -f

# Обновление образа и откат, если что-то не так
kubectl set image deployment/my-app app=nginx:1.28 --record
kubectl rollout status deployment/my-app
kubectl rollout undo deployment/my-app   # если плохо

# Зайти в под и посмотреть события при проблеме
kubectl exec -it my-app-<hash> -- sh
kubectl describe pod my-app-<hash>
kubectl get events --sort-by=.lastTimestamp
```

## Быстрая навигация

- **Доступ**: `kubectl config current-context`, `kubectl config use-context`
- **Обзор**: `kubectl get nodes`, `kubectl cluster-info`, `kubectl get namespaces`
- **Поды**: `kubectl get pods`, `kubectl describe pod`, `kubectl logs`, `kubectl exec`
- **Деплой**: `kubectl apply -f`, `kubectl get deploy`, `kubectl scale`, `kubectl set image`
- **Откат**: `kubectl rollout status/history/undo`
- **Сеть**: `kubectl get svc`, `kubectl get ingress`, `kubectl port-forward`
- **Диагностика**: `kubectl get events`, `kubectl top`, `kubectl explain`

> Все команды с флагами и разбором — на странице [Kubernetes: команды с подробным описанием](k8s-commands.md).
