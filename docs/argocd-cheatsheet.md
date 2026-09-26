# Argo CD: шпаргалка

Самые частые команды `argocd` CLI и `kubectl` при работе с GitOps.

> Теория — [GitOps и Argo CD](gitops.md).

## Топ-20

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | доступ | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | открыть UI на localhost:8080 |
| 2 | доступ | `argocd login localhost:8080 --username admin --insecure` | войти в CLI |
| 3 | доступ | `argocd admin initial-password -n argocd` | начальный пароль admin |
| 4 | обзор | `argocd app list` | все приложения и их статусы |
| 5 | обзор | `argocd app get <app>` | детали: sync, health, ресурсы |
| 6 | обзор | `kubectl get applications -n argocd` | то же через kubectl |
| 7 | разбор | `argocd app diff <app>` | чем кластер отличается от git |
| 8 | разбор | `argocd app manifests <app>` | итоговые манифесты, которые применяются |
| 9 | деплой | `argocd app sync <app>` | синхронизировать вручную |
| 10 | деплой | `argocd app sync <app> --prune` | синхронизировать с удалением лишнего |
| 11 | деплой | `argocd app refresh <app>` | перечитать git сейчас (не ждать опроса) |
| 12 | деплой | `argocd app wait <app> --health --timeout 300` | дождаться Healthy (для CI) |
| 13 | история | `argocd app history <app>` | история синхронизаций |
| 14 | откат | `argocd app rollback <app> <id>` | откат к прошлой синхронизации (без autosync) |
| 15 | создание | `argocd app create <app> --repo <url> --path <dir> --dest-server https://kubernetes.default.svc --dest-namespace <ns>` | создать Application из CLI |
| 16 | настройка | `argocd app set <app> --sync-policy automated --self-heal --auto-prune` | включить автосинхронизацию |
| 17 | репо | `argocd repo add <url> --username <u> --password <token>` | подключить приватный репозиторий |
| 18 | кластеры | `argocd cluster add <kube-context>` | добавить внешний кластер |
| 19 | удаление | `argocd app delete <app>` | удалить приложение и его ресурсы |
| 20 | логи | `kubectl logs -n argocd deploy/argocd-repo-server` | ошибки рендера Helm/Kustomize |

## Статусы

| Sync | Health | Что делать |
|---|---|---|
| Synced | Healthy | всё хорошо |
| OutOfSync | Healthy | в git есть изменения или drift — `argocd app diff` |
| Synced | Progressing | идёт раскатка, подождать |
| Synced | Degraded | применили, но не работает — поды, события, логи |
| Unknown | — | ошибка рендера или доступа к репо — `argocd app get` |

## Минимальный Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/me/k8s-config.git
    targetRevision: main
    path: apps/myapp/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```
