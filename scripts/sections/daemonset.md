### DaemonSet — под на каждом узле
**DaemonSet** — ресурс, который гарантирует, что на каждом узле кластера (или на выбранных по селектору) работает **по одному поду**.

Подходит для агентов уровня кластера: сбор логов, мониторинг (node-exporter), сетевые и системные агенты.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      containers:
      - name: node-exporter
        image: prom/node-exporter:latest
      hostNetwork: true     # под работает в сети узла
```

> При появлении нового узла DaemonSet автоматически запускает на нём под; при удалении узла — останавливает. Не стоит использовать для статeless-приложений с множеством реплик — для этого есть Deployment.
