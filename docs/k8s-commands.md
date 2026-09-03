# Kubernetes: команды с подробным описанием

Основные команды `kubectl`. Теория (архитектура, манифесты, понятия) — на странице [Kubernetes (теория)](k8s.md).

> Мини-шпаргалка «топ-20»: [Kubernetes: шпаргалка топ-20 команд](k8s-cheatsheet.md).
> Удобный TUI-обозреватель: [k9s — быстрая навигация по кластеру](k9s.md).

`kubectl` — универсальный клиент API-сервера. Общий синтаксис:
```
kubectl <команда> <тип ресурса> [имя] [флаги]
```

---

## Настройка доступа

### kubectl
* `kubectl` - CLI для работы с кластером
* `kubectl version --client` - версия клиента
* `kubectl version` - версия клиента и сервера

```
$ kubectl version --client
Client Version: v1.30.0
```

### Конфигурация (kubeconfig)
* `kubectl config current-context` - текущий контекст (кластер+пользователь+namespace)
* `kubectl config get-contexts` - список всех контекстов
* `kubectl config use-context <имя>` - переключить контекст
* `kubectl config set-context <имя> --namespace <ns>` - задать namespace контекста

```
$ kubectl config get-contexts
CURRENT   NAME          CLUSTER      AUTHINFO   NAMESPACE
*         minikube      minikube     minikube   default
```

> Контекст = «какой кластер + какой пользователь + в каком namespace я сейчас». Меняя кластер в облаке, вы не «ломаете» доступ к другому — просто переключаете контекст.

---

## Обзор кластера

### kubectl get nodes
* `kubectl get nodes` - список нод кластера (worker-ноды и control plane)
* `kubectl get nodes -o wide` - с IP и версиями
* `kubectl describe node <имя>` - детали по конкретной ноде

```
$ kubectl get nodes
NAME       STATUS   ROLES           AGE    VERSION
node-1     Ready    control-plane   12d    v1.30.0
node-2     Ready    <none>          12d    v1.30.0
node-3     Ready    <none>          12d    v1.30.0
```

> Видите ноды со статусом `Ready` — значит доступ к API-серверу настроен и кластер живой.

### kubectl cluster-info
* `kubectl cluster-info` - адрес API-сервера и другие сервисы кластера

```
$ kubectl cluster-info
Kubernetes control plane is running at https://...
CoreDNS is running at https://...
```

### kubectl get namespaces
* `kubectl get namespaces` - список namespace
* `kubectl create namespace <имя>` - создать namespace
* `kubectl delete namespace <имя>` - удалить namespace

```
$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   12d
kube-system       Active   12d
dev               Active   3d
```

> `default` — куда попадают ресурсы без явного namespace. `kube-system` — служебные поды самого кластера.

---

## Работа с подами

### kubectl get pods
* `kubectl get pods` - список подов в текущем namespace
* `kubectl get pods -A` - поды во всех namespace
* `kubectl get pods -n <ns>` - поды в конкретном namespace
* `kubectl get pods -o wide` - с IP и нодой
* `kubectl get pods -l app=my-app` - фильтр по меткам
* `kubectl get pods --watch` - наблюдать за изменениями в реальном времени

```
$ kubectl get pods
NAME                      READY   STATUS    RESTARTS   AGE
my-app-6f4b7f9c7d-abc12   1/1     Running   0          5m
my-app-6f4b7f9c7d-def34   1/1     Running   0          5m
```

> `READY 1/1` — из одного контейнера в поде один готов. `STATUS CrashLoopBackOff` — контейнер падает и перезапускается по кругу, надо смотреть логи.

### kubectl describe pod
* `kubectl describe pod <имя>` - детальная информация: события, образ, нода, пробы

```
$ kubectl describe pod my-app-6f4b7f9c7d-abc12
...
Events:
  Type    Reason     Age   From               Message
  Normal  Scheduled  5m    default-scheduler  Successfully assigned ...
  Normal  Pulling    5m    kubelet            Pulling image nginx:1.27
  Normal  Started    5m    kubelet            Started container app
```

> `Events` внизу — главный инструмент диагностики: почему под не запустился, что перезапускалось и т.п.

### kubectl logs
* `kubectl logs <pod>` - логи контейнера пода
* `kubectl logs <pod> -c <контейнер>` - логи конкретного контейнера (если их несколько)
* `kubectl logs -f <pod>` - следить за логами в реальном времени
* `kubectl logs <pod> --tail=50` - последние 50 строк
* `kubectl logs -l app=my-app` - логи всех подов по метке

```
$ kubectl logs my-app-6f4b7f9c7d-abc12 --tail=20
2026-09-03 12:00:01 INFO  server started on :80
2026-09-03 12:01:15 INFO  request GET / 200
```

> Для нескольких реплик (Deployment) удобнее `kubectl logs deployment/my-app` — аггрегирует логи всех подов деплоймента.

### kubectl exec
* `kubectl exec -it <pod> -- sh` - зайти в интерактивный shell внутрь контейнера
* `kubectl exec <pod> -- <команда>` - выполнить команду без интерактива
* `kubectl exec <pod> -c <контейнер> -- <команда>` - для конкретного контейнера

```
$ kubectl exec -it my-app-6f4b7f9c7d-abc12 -- sh
# внутри пода
$ ls /app
```

> Синтаксис `kubectl exec <pod> -- <cmd>`: в отличие от `docker exec`, здесь команда идёт после `--`, иначе флаги kubectl перепутаются с командами внутри.

### kubectl port-forward
* `kubectl port-forward <pod> <port>:<port>` - пробросить локальный порт на под (для быстрой проверки)

```
$ kubectl port-forward pod/my-app-6f4b7f9c7d-abc12 8080:80
Forwarding from 127.0.0.1:8080 -> 80
```

> Локальная отладка: открывает порт на вашей машине к поду, минуя Service/Ingress. Удобно для проверки, когда внешний доступ ещё не настроен.

---

## Работа с Deployment

### kubectl apply
* `kubectl apply -f <файл>.yaml` - применить манифест (создать/обновить ресурс)
* `kubectl apply -f <папка>/` - применить все YAML из папки
* `kubectl delete -f <файл>.yaml` - удалить ресурсы, описанные в манифесте

```
$ kubectl apply -f deployment.yaml
deployment.apps/my-app created
```

> `apply` — декларативный подход: Kubernetes хранит желаемое состояние и приводит факт к нему. Повторный `apply` не уронит уже запущенное.

### kubectl get deployment
* `kubectl get deployment` / `kubectl get deploy` - список деплойментов
* `kubectl get deployment -o wide` - с образами
* `kubectl get deploy my-app -o yaml` - манифест в текущем состоянии

```
$ kubectl get deploy
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
my-app   3/3     3            3           6m
```

> `READY 3/3` — три реплики желаемы и три доступны. `UP-TO-DATE` — сколько обновлено до текущей версии.

### kubectl scale
* `kubectl scale deployment <имя> --replicas=<N>` - изменить число реплик

```
$ kubectl scale deployment my-app --replicas=5
deployment.apps/my-app scaled
```

> Быстрый способ «на лету», но лучше править `replicas` в манифесте и делать `apply` — тогда масштаб зафиксирован в коде.

### kubectl rollout
* `kubectl rollout status deployment/<имя>` - следить за выкатом
* `kubectl rollout history deployment/<имя>` - история ревизий
* `kubectl rollout undo deployment/<имя>` - откат к предыдущей ревизии
* `kubectl rollout restart deployment/<имя>` - перезапустить поды (например, чтобы перечитать ConfigMap)

```
$ kubectl rollout status deployment/my-app
deployment "my-app" successfully rolled out

$ kubectl rollout history deployment/my-app
REVISION  CHANGE-CAUSE
1         kubectl apply --filename=deployment.yaml
2         kubectl set image deployment/my-app app=nginx:1.28

$ kubectl rollout undo deployment/my-app
deployment.apps/my-app rolled back
```

> Rolling update обновляет поды постепенно, без даунтайма. `rollout undo` откатывает на предыдущую ревизию — надежный откат при плохом выкате.

### kubectl set image
* `kubectl set image deployment/<имя> <контейнер>=<образ> --record` - сменить образ контейнера

```
$ kubectl set image deployment/my-app app=nginx:1.28 --record
deployment.apps/my-app image updated
```

> Альтернатива правке манифеста. `--record` сохраняет ревизию с пометкой в `rollout history`.

---

## Service, Ingress и сеть

### kubectl get svc
* `kubectl get svc` / `kubectl get service` - список Service
* `kubectl get svc -o wide` - с IP и портами
* `kubectl get endpoints` - какие поды реально за Service

```
$ kubectl get svc
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
my-app       ClusterIP   10.96.0.10      <none>        80/TCP    6m
kubernetes    ClusterIP   10.96.0.1       <none>        443/TCP   12d
```

> Service `ClusterIP` доступен только внутри кластера по стабильному имени. Для внешнего доступа — Ingress или NodePort/LoadBalancer.

### kubectl apply -f service.yaml / ingress.yaml
* `kubectl apply -f service.yaml` - создать Service
* `kubectl apply -f ingress.yaml` - создать Ingress (правила HTTP-доступа)

```
$ kubectl get ingress
NAME            CLASS    HOSTS              ADDRESS   PORTS   AGE
my-app-ingress  nginx    app.example.com             80      4m
```

> Ingress маршрутизирует внешний HTTP-трафик по доменам и путям к Service. Работает только если в кластере есть ingress-controller.

---

## Конфигурация и секреты

### kubectl get configmap / get secret
* `kubectl get configmap` / `kubectl get cm` - список ConfigMap
* `kubectl get secret` - список Secret
* `kubectl get configmap <имя> -o yaml` - содержимое
* `kubectl get secret <имя> -o yaml` - содержимое (в base64)

```
$ kubectl get cm
NAME         DATA   AGE
app-config   2      5m
```

> Секреты и конфиг — это отдельные ресурсы, которые подключаются в поды. Данные Secret хранятся в base64 — это кодирование, а не шифрование.

### kubectl create configmap / create secret
* `kubectl create configmap <имя> --from-literal=KEY=value` - создать из значений
* `kubectl create configmap <имя> --from-file=<файл>` - создать из файла
* `kubectl create secret generic <имя> --from-literal=KEY=value` - создать secret

```
$ kubectl create configmap app-config --from-literal=LOG_LEVEL=info
configmap/app-config created

$ kubectl create secret generic app-secret --from-literal=DB_PASSWORD=hunter2
secret/app-secret created
```

---

## Пробы и автоскейлинг

### kubectl get hpa
* `kubectl get hpa` - статус горизонтального автоскейлинга (HorizontalPodAutoscaler)
* `kubectl apply -f hpa.yaml` - применить HPA-манифест

```
$ kubectl get hpa
NAME         REFERENCE          TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
my-app-hpa   Deployment/my-app  45%/70%   2         10        4          10m
```

> `TARGETS 45%/70%` — текущая загрузка CPU 45% при цели 70%. Когда переходит порог — поды автоматически добавляются/убираются.

---

## Диагностика: события и ресурсы

### kubectl get events
* `kubectl get events` - все события в namespace
* `kubectl get events --sort-by=.lastTimestamp` - отсортированные по времени
* `kubectl get events --field-selector involvedObject.name=<pod>` - события по конкретному объекту

```
$ kubectl get events
LAST SEEN   TYPE      REASON              OBJECT              MESSAGE
2m          Normal    Scheduled           pod/my-app-...       Successfully assigned ...
1m          Warning   BackOff             pod/my-app-...       Back-off restarting failed container
```

> Events — кладезь диагностики: предупреждения о перезапусках, нехватке ресурсов, FailedScheduling и т.п.

### kubectl top
* `kubectl top pod` - потребление CPU/памяти подами
* `kubectl top node` - потребление нодами
* `kubectl top pod -l app=my-app` - по метке

```
$ kubectl top pod
NAME                      CPU(cores)   MEMORY(bytes)
my-app-6f4b7f9c7d-abc12   5m           18Mi
```

> Требует установленного metrics-server. Показывает фактические ресурсы — полезно для настройки requests/limits и HPA.

### kubectl delete
* `kubectl delete pod <имя>` - удалить под (Deployment создаст новый)
* `kubectl delete deployment <имя>` - удалить деплоймент и его поды
* `kubectl delete svc <имя>` - удалить Service
* `kubectl delete ns <имя>` - удалить namespace и всё в нём
* `kubectl delete -f <файл>.yaml` - удалить то, что описано в манифесте

> `kubectl delete pod` у пода, которым управляет Deployment, — под пересоздастся (самовосстановление). Чтобы реально удалить — удаляй Deployment.

### kubectl explain
* `kubectl explain <тип>` - документация по полям ресурса прямо в CLI
* `kubectl explain <pod>.spec.containers` - углубиться в вложенные поля

```
$ kubectl explain pod.spec.containers.livenessProbe
KIND:     Pod
VERSION:  v1
RESOURCE: livenessProbe <Object>
...
```

> Встроенная справка по схеме ресурсов. Не нужно лезть в интернет — `kubectl explain` расскажет, какие поля поддерживает манифест.
