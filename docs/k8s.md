# Kubernetes

Kubernetes (k8s) — платформа для оркестрации контейнеров. Автоматизирует развёртывание, масштабирование и управление контейнеризованными приложениями, позволяя описывать «желаемое состояние» кластера декларативно: вы говорите, что хотите, а Kubernetes приводит систему к этому состоянию.

`кластер` — набор машин (нод), на которых работает Kubernetes: control plane (плоскость управления) + рабочие ноды.

`нода (node)` — физическая или виртуальная машина в кластере.

`плоскость управления (control plane)` — компоненты, которые управляют кластером (kube-apiserver, etcd, scheduler, controller-manager).

`под (pod)` — минимальная неделимая единица Kubernetes: один или несколько контейнеров, которые делят сеть, IPC и том. Обычно под = один контейнер.

`манифест` — YAML-файл с декларативным описанием желаемого состояния ресурса.

`kubectl` — CLI для общения с API-сервером кластера.

> Этот конспект построен по курсу из 7 уроков:
> 1. Системы оркестрации контейнеров
> 2. Получение доступа к Kubernetes
> 3. Первый деплой в Kubernetes
> 4. Модель ответственности Kubernetes
> 5. Типовые задачи деплоя. Часть 1
> 6. Типовые задачи деплоя. Часть 2
> 7. Надёжность и автоматизация

---

## Урок 1. Системы оркестрации контейнеров

Зачем вообще нужна оркестрация? Docker управляет одним контейнером на одной машине. Когда приложений много, их нужно масштабировать, перезапускать при сбоях, распределять по машинам, обновлять без даунтайма — это и делает оркестратор.

### Что умеет оркестратор
- **Деплой**: запустить N реплик приложения раскидав их по нодам
- **Масштабирование**: увеличить/уменьшить число реплик (вручную или автоматически)
- **Самовосстановление**: перезапустить под, если он упал или нода вышла из строя
- **Обновление**: выкатить новую версию без простоя (rolling update), с возможностью отката
- **Балансировка**: распределять трафик между репликами и давать стабильную точку входа
- **Хранение**: монтировать тома, привязывать их к подам

### Кто есть на рынке
| Система | Кто развивает | Особенности |
|---|---|---|
| **Kubernetes** | CNCF | стандарт де-факто, огромная экосистема |
| **Docker Swarm** | Docker | простой, встроен в Docker, но почти вымер |
| **Nomad** | HashiCorp | простой и быстрый, поддерживает не только контейнеры |
| **OpenShift** | Red Hat | Kubernetes + доп. инструменты для корпораций |

> Kubernetes победил как стандарт: он не привязан к конкретному вендору, работает во всех облаках и on-premise, у него самая большая экосистема.

---

## Урок 2. Получение доступа к Kubernetes

Чтобы работать с кластером, нужны:
1. **kubectl** — клиент на вашей машине
2. **kubeconfig** — файл с параметрами подключения (адрес API-сервера, контекст, учётные данные)

### kubectl
```bash
# установка (macOS)
brew install kubectl

# проверить версию клиента и сервера
kubectl version --client
kubectl version
```

### kubeconfig
По умолчанию `kubectl` берёт конфиг из `~/.kube/config`. В нём описываются:
- **clusters** — адреса API-серверов
- **contexts** — связка «кластер + пользователь + namespace» (текущая рабочая точка)
- **users** — учётные данные

```bash
# посмотреть текущий контекст
kubectl config current-context

# переключение контекста
kubectl config use-context <имя>

# список всех контекстов
kubectl config get-contexts
```

> На практике для облака (Yandex Cloud, Salt Cloud) kubeconfig часто скачивается готовым через CLI облака:
> ```bash
> # например для Yandex Cloud
> yc managed-kubernetes cluster get-credentials <cluster-id> --external
> ```
> либо выгружается из интерфейса облака и кладётся в `~/.kube/config`.

### Базовая проверка доступа
```bash
# какие ноды в кластере (главная проверка, что доступ работает)
kubectl get nodes

# какой API-сервер отвечает
kubectl cluster-info
```

> `kubectl get nodes` видит ноды — значит, доступ настроен корректно и API-сервер отвечает.

---

## Урок 3. От контейнера к кластеру: первый деплой

Первый деплой — это ключевой сценарий: вы берёте образ из Dockerfile и «поднимаете» его в кластере.

### Декларативный подход
Вместо длинной команды (как `docker run`) вы пишете **манифест** — YAML с описанием того, что должно быть. Kubernetes сам создаёт и поддерживает это состояние.

```yaml
# manifest.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
```

Этот манифест говорит: «хочу, чтобы 3 реплики nginx работали, с меткой app:my-app».

### Применить манифест
```bash
kubectl apply -f manifest.yaml
kubectl get deployments
kubectl get pods
```

> `kubectl apply` — декларативно: сравнивает желаемое состояние из манифеста с фактическим и приводит к желаемому. `kubectl create` — проще/императивно, применяет манифест как есть.

### Промежуточные структуры
Между манифестом и подом есть прослойки:
- **Deployment** — управляет ReplicaSet
- **ReplicaSet** — управляет количеством подов (реплик)
- **Pod** — фактически запущенный контейнер(ы)

```
Deployment -> ReplicaSet -> Pod(s)
```

> На практике вы работаете в основном с Deployment, а ReplicaSet и Pod управляются автоматически.

### Service
Под — это «эфемерное существо»: его IP меняется при перезапуске. Для стабильной точки входа нужен **Service** — абстракция с постоянным адресом (ClusterIP/DNS), которая балансирует трафик по подам с нужной меткой.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f service.yaml
kubectl get svc
```

> Service «цепляется» к подам через `selector` (по меткам). У Service стабильное DNS-имя внутри кластера: `<service>.<namespace>.svc` .

---

## Урок 4. Как работает Kubernetes: модель ответственности

Ключевая идея — **декларативное желаемое состояние** и **control loop** (петля управления).

### Кто за что отвечает (control plane)
| Компонент | Ответственность |
|---|---|
| **kube-apiserver** | единственная точка входа в кластер, вся работа через него (kubectl = клиент apiserver) |
| **etcd** | хранилище состояния кластера (единый источник истины) |
| **kube-scheduler** | решает, на какую ноду поставить новый под |
| **kube-controller-manager** | запускает контроллеры, которые поддерживают желаемое состояние |
| **kubelet** (на нодах) | агент на каждой ноде: запускает/останавливает контейнеры, докладывает о состоянии |
| **kube-proxy** (на нодах) | сети/балансировка Service |

### Как это работает (желаемое состояние -> факт)
1. Вы пишете манифест (`kubectl apply`).
2. apiserver сохраняет желаемое состояние в etcd.
3. Контроллеры (в controller-manager) видят разницу между желаемым и фактическим.
4. Scheduler назначает поды на ноды.
5. kubelet каждой ноды запускает контейнеры и сообщает статус обратно.
6. Если под упал — контроллер создаёт новый (самовосстановление).

```
kubectl apply -> apiserver -> etcd -> controllers -> scheduler -> kubelet -> pod
```

> Модель ответственности в том, что каждый компонент делает только свою работу. Вы описываете ЧТО должно быть, а Kubernetes сам решает КАК это обеспечить.

### Namespace — изоляция внутри кластера
Namespace логически разделяют кластер на части (dev, prod, команды).

```bash
kubectl get namespaces
kubectl create namespace dev
kubectl get pods -n dev
```

---

## Урок 5. Решение типовых задач деплоя. Часть 1

### Масштабирование
```bash
# изменить число реплик
kubectl scale deployment my-app --replicas=5
# или отредактировать манифест (replicas: 5) и apply
```

> Предпочтительнее править манифест и делать `apply` — так желаемое состояние зафиксировано в коде (GitOps), а не только в рантайме.

### Обновление (rolling update) и откат
```bash
# сменить образ и сохранить историю (для отката)
kubectl set image deployment/my-app app=nginx:1.28 --record
# или через apply нового манифеста

# следить за выкатом
kubectl rollout status deployment/my-app

# история версий
kubectl rollout history deployment/my-app

# откат к предыдущей
kubectl rollout undo deployment/my-app
```

> Rolling update обновляет поды постепенно, не останавливая сервис. `--record` сохраняет причину в истории.

### Конфигурация: ConfigMap и Secret
Настройки и секреты выносят из кода в отдельные ресурсы.

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  APP_COLOR: blue
  LOG_LEVEL: info
```
```bash
kubectl apply -f configmap.yaml
```

```yaml
# secret.yaml (значения в base64)
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
  DB_PASSWORD: cGFzc3dvcmQ=
```
```bash
kubectl apply -f secret.yaml
```

Подключаются в манифест через `env` или `volume`:
```yaml
env:
  - name: APP_COLOR
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: APP_COLOR
```

> Секреты хранятся в base64 — это не шифрование, просто кодирование. Для серьёзных секретов используй внешние хранилища или шифрование etcd.

### Логи и отладка
```bash
kubectl logs deployment/my-app
kubectl logs -l app=my-app --tail=50 -f
kubectl describe pod <pod>
kubectl get events
```

---

## Урок 6. Решение типовых задач деплоя. Часть 2

### HTTP-доступ: Ingress
Service работает внутри кластера. Чтобы во внешний мир отдавать HTTP-трафик по доменам/путям и с TLS — нужен **Ingress**.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```
```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

> Ingress требует установленного ingress-controller (nginx, traefik и т.п.). Это «внешний» роутер, который берёт правила из Ingress-объектов.

### Постоянное хранилище: PVC / PV
Для данных, которые должны пережить перезапуск пода, используют PersistentVolume (PV) и PersistentVolumeClaim (PVC).

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```
```bash
kubectl apply -f pvc.yaml
```

PVC подключается в под через `volumes`:
```yaml
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: app-data
```

> Pod -> PVC -> PV -> реальное хранилище (диск облака, NFS). PVC — это «заявка» на диск.

### Healthcheck: liveness и readiness
Kubernetes проверяет здоровье подов:
- **livenessProbe** — жив ли процесс; если нет, контейнер перезапускают
- **readinessProbe** — готов ли принимать трафик; если нет, под убирают из Service

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
```

> liveness — «жив ли», readiness — «готов ли принимать трафик». Разница критична: под может быть жив, но ещё не готов (грузит данные), тогда его не надо нагружать трафиком.

### Метки и селекторы (labels / selectors)
Метки — ключевой механизм группировки ресурсов. Service, ReplicaSet и другие «цепляются» к подам по меткам.

```bash
kubectl get pods -l app=my-app
kubectl label pod <pod> version=v2
kubectl get pods --show-labels
```

---

## Урок 7. Надёжность и автоматизация в Kubernetes

### Самовосстановление
Kubernetes сам перезапускает упавшие поды, пересоздаёт их на живых нодах. Это встроенное самовосстановление из модели желаемого состояния.

### Ресурсы: requests / limits
Квотирование ресурсов защищает кластер: под получает минимум (requests) и не может съесть больше лимита (limits).

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

> `cpu: 100m` = 0.1 ядра (milicpu). Requests — резервирование, limits — жёсткий потолок. Не задать limits при перегрузке — плохой сосед в кластере.

### Horizontal Pod Autoscaler (HPA)
Автоматическое масштабирование по нагрузке CPU/памяти.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```
```bash
kubectl apply -f hpa.yaml
kubectl get hpa
```

### Ресурсы декларативно и GitOps
Главная практика надёжности — вся конфигурация хранится как код (манифесты), версионируется в git, выкатывается автоматически (Argo CD, Flux). Тогда состояние кластера воспроизводимо и отслеживаемо.

### PodDisruptionBudget (PDB)
Ограничение: сколько подов может недоступно одновременно при плановых обслуживаниях (эвакуация нод).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: my-app
```

---

## Ключевые понятия

| Понятие | Что это |
|---|---|
| Pod | минимальная единица (контейнер + его окружение) |
| Deployment | декларативное описание «сколько реплик и какой образ» |
| ReplicaSet | поддерживает число реплик |
| Service | стабильная точка входа к подам (балансировка) |
| Ingress | внешний HTTP-доступ по доменам/путям + TLS |
| ConfigMap / Secret | конфигурация и секреты вне кода |
| PV / PVC | постоянное хранилище |
| Namespace | логическая изоляция кластера |
| HPA | автоскейлинг по нагрузке |
| PDB | гарантия доступности при обслуживании |

> Команды `kubectl` — на странице [Kubernetes: команды с подробным описанием](k8s-commands.md).
> Мини-шпаргалка: [Kubernetes: шпаргалка топ-20 команд](k8s-cheatsheet.md).
> Удобный TUI-обозреватель кластера: [k9s — быстрая навигация по кластеру](k9s.md).
