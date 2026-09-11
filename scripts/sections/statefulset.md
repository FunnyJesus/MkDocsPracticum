### StatefulSet — приложения с состоянием
**StatefulSet** — ресурс для подов, которым нужны уникальные стабильные имена и постоянные тома. В отличие от Deployment, поды стартуют/останавливаются в строгом порядке и сохраняют идентичность при перезапуске.

Подходит для **Stateful**-приложений: базы данных, очереди сообщений, кластеры с мастером и репликами.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db          # headless-сервис для стабильных DNS-имён подов
  replicas: 2
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: db
        image: postgres:16
  volumeClaimTemplates:    # автоматически создаёт PVC для каждого пода
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```

> Поды StatefulSet получают стабильные имена вида `<name>-0`, `<name>-1` и собственные тома. Порядок старта/остановки гарантирован. Обычный выбор для баз данных, когда нужна «запоминающая» идентичность подов.
