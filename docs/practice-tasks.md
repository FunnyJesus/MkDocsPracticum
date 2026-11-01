# Практические задания

Задания «руками» по темам конспекта: написать Dockerfile, поднять мониторинг, задеплоить в кластер,
найти поломку. Всё делается **локально и бесплатно** — облако не нужно. Эти же задания раз в несколько
дней присылает бот-тренажёр.

## Окружение

| Инструмент | Зачем | Установка (macOS) |
|---|---|---|
| Docker (Desktop или OrbStack) | контейнеры, compose | `brew install --cask orbstack` |
| kind | Kubernetes в Docker | `brew install kind` |
| kubectl, helm | работа с кластером | `brew install kubectl helm` |
| Terraform | IaC с провайдером Docker | `brew install hashicorp/tap/terraform` |
| hadolint, shellcheck, trivy | линтеры и сканер | `brew install hadolint shellcheck trivy` |

Формат задания: **уровень и время** → **цель** → **требования** → **проверка** → подсказка и решение
под спойлерами. Сначала сделай сам, потом сверяйся.

Уровни: ★☆☆ — разогрев, ★★☆ — рабочая задача, ★★★ — с подвохом или несколько компонентов.

---

## Docker

### Задача 1. Dockerfile для Go-сервиса

**Уровень:** ★☆☆ · **Время:** ~30 мин

**Цель.** Собрать минимальный и безопасный образ для Go-сервиса.

```go
// main.go — go mod init example.com/hello
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, "ok") })
	http.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "hello") })
	http.ListenAndServe(":8080", nil)
}
```

**Требования.**

- multi-stage сборка, итоговый образ **меньше 15 МБ**;
- запуск **не от root**, работает с `--read-only`;
- зависимости (`go.mod`) кэшируются отдельным слоем;
- `hadolint Dockerfile` — без замечаний.

**Проверка.**

```bash
docker build -t hello:1.0 .
docker images hello:1.0                                  # размер
docker run -d --name hello --read-only -p 8080:8080 hello:1.0
curl localhost:8080/health                               # ok
docker exec hello id 2>&1 || docker inspect hello -f '{{.Config.User}}'   # не root
```

??? tip "Подсказка"
    Бинарник Go можно собрать статическим (`CGO_ENABLED=0`) — тогда ему не нужна даже libc и подойдёт
    пустой образ `scratch`. Пользователя в `scratch` нет — задай его числом.

??? success "Решение"
    ```dockerfile
    FROM golang:1.25-alpine AS build
    WORKDIR /src
    COPY go.mod ./
    RUN go mod download
    COPY . .
    RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/hello .

    FROM scratch
    COPY --from=build /out/hello /hello
    USER 65532:65532
    EXPOSE 8080
    ENTRYPOINT ["/hello"]
    ```

    **Почему так.** `go.mod` копируется до кода — при правке кода зависимости не перекачиваются.
    `-s -w` убирает отладочную информацию. В `scratch` нет shell, поэтому `docker exec hello id`
    не сработает — пользователя смотри через `docker inspect`. Если сервису нужны HTTPS-запросы наружу —
    скопируй CA-сертификаты из build-стадии или возьми `gcr.io/distroless/static`.

---

### Задача 2. Dockerfile для Python-сервиса с healthcheck

**Уровень:** ★★☆ · **Время:** ~40 мин

**Цель.** Образ для FastAPI-приложения, который быстро пересобирается и сам сообщает о своём здоровье.

```python
# app.py
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health():
    return {"status": "ok"}
```

`requirements.txt`: `fastapi==0.115.6` и `uvicorn==0.34.0`.

**Требования.**

- база `python:3.12-slim`, без кэша pip в образе;
- при изменении только `app.py` слой с `pip install` **не пересобирается**;
- `.dockerignore` (без `.git`, `__pycache__`, `.venv`);
- не root; `HEALTHCHECK` — контейнер становится `healthy`.

**Проверка.**

```bash
docker build -t pyapp:1 .
echo "# change" >> app.py && docker build -t pyapp:2 .   # pip install — CACHED
docker run -d --name pyapp -p 8000:8000 pyapp:2
sleep 15 && docker ps --filter name=pyapp                 # (healthy)
```

??? tip "Подсказка"
    В `slim`-образе нет `curl`. Для `HEALTHCHECK` можно использовать сам Python:
    `python -c "import urllib.request; urllib.request.urlopen(...)"`.

??? success "Решение"
    ```dockerfile
    FROM python:3.12-slim
    ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
    WORKDIR /app

    COPY requirements.txt .
    RUN pip install --no-cache-dir -r requirements.txt

    COPY app.py .
    RUN useradd --system --uid 10001 app
    USER app

    EXPOSE 8000
    HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
      CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"
    CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
    ```

    **Почему так.** Порядок слоёв: сначала то, что меняется редко (зависимости), потом код.
    `--host 0.0.0.0` обязателен — по умолчанию uvicorn слушает только `127.0.0.1` внутри контейнера,
    и снаружи до него не достучаться. В Kubernetes `HEALTHCHECK` игнорируется — там пробы.

---

### Задача 3. Исправь плохой Dockerfile

**Уровень:** ★★☆ · **Время:** ~30 мин

**Цель.** Найти и исправить всё, что делает образ большим, медленным и небезопасным.

```dockerfile
FROM node:20
COPY . /app
WORKDIR /app
RUN apt-get update
RUN apt-get install -y curl vim
RUN npm install
EXPOSE 3000
CMD npm start
```

**Требования.** Назови не меньше 6 проблем, исправь их и сравни: размер образа и время пересборки
после правки одного `.js`-файла — до и после.

**Проверка.**

```bash
docker build -t bad . && docker images bad
time docker build -t good -f Dockerfile.good . && docker images good
hadolint Dockerfile.good
```

??? tip "Подсказка"
    Смотри на: базовый образ, порядок `COPY`, кэш слоёв, лишние пакеты, отдельный `apt-get update`,
    `npm install` vs `npm ci`, dev-зависимости, пользователя, форму `CMD`, `.dockerignore`.

??? success "Решение"
    Проблемы: полный `node:20` (~1 ГБ); `COPY .` до установки зависимостей — любая правка кода
    сбрасывает кэш `npm install`; `apt-get update` отдельным слоем (устаревший кэш индекса);
    `vim`/`curl` в проде не нужны; `npm install` вместо воспроизводимого `npm ci`; dev-зависимости в
    образе; запуск от root; shell-форма `CMD` — `npm` получает сигналы через `sh`, плохой graceful
    shutdown; без `.dockerignore` в контекст летит `node_modules` и `.git`.

    ```dockerfile
    FROM node:20-alpine
    WORKDIR /app
    COPY package.json package-lock.json ./
    RUN npm ci --omit=dev && npm cache clean --force
    COPY . .
    USER node
    EXPOSE 3000
    CMD ["node", "server.js"]
    ```

    `.dockerignore`: `node_modules`, `.git`, `*.log`, `Dockerfile*`. Если есть шаг сборки
    (TypeScript, фронтенд) — multi-stage: собрать в одной стадии, скопировать результат в чистую.

---

## Docker Compose

### Задача 4. Prometheus + Grafana + node-exporter

**Уровень:** ★★☆ · **Время:** ~1 ч

**Цель.** Поднять стек мониторинга одной командой, без ручной настройки в интерфейсе.

**Требования.**

- `compose.yaml`: `prometheus`, `grafana`, `node-exporter`;
- Prometheus собирает метрики с node-exporter и с самого себя, retention 2 дня;
- источник данных Prometheus в Grafana создаётся **provisioning-файлом**;
- данные Prometheus и Grafana переживают `docker compose down` / `up` (тома);
- импортирован дашборд «Node Exporter Full» (ID `1860`).

**Проверка.**

```bash
docker compose up -d
open http://localhost:9090/targets       # оба таргета UP
open http://localhost:3000               # admin/admin, Connections → Data sources — Prometheus уже есть
```

??? tip "Подсказка"
    Сервисы в одной compose-сети видят друг друга по имени: таргет — `node-exporter:9100`.
    Grafana читает `/etc/grafana/provisioning/datasources/*.yaml` при старте.

??? success "Решение"
    ```yaml
    # compose.yaml
    services:
      prometheus:
        image: prom/prometheus:v3.1.0
        command:
          - --config.file=/etc/prometheus/prometheus.yml
          - --storage.tsdb.retention.time=2d
        volumes:
          - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
          - prom-data:/prometheus
        ports: ["9090:9090"]

      node-exporter:
        image: prom/node-exporter:v1.8.2

      grafana:
        image: grafana/grafana:11.4.0
        volumes:
          - ./grafana/datasources:/etc/grafana/provisioning/datasources:ro
          - grafana-data:/var/lib/grafana
        ports: ["3000:3000"]

    volumes:
      prom-data:
      grafana-data:
    ```

    ```yaml
    # prometheus.yml
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: prometheus
        static_configs: [{ targets: ["localhost:9090"] }]
      - job_name: node
        static_configs: [{ targets: ["node-exporter:9100"] }]
    ```

    ```yaml
    # grafana/datasources/prometheus.yaml
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus:9090
        isDefault: true
    ```

    Дашборд: Dashboards → New → Import → `1860` → источник Prometheus. На macOS node-exporter
    показывает метрики Linux-ВМ Docker, а не самого Mac — это нормально.

---

### Задача 5. Nginx как балансировщик перед репликами

**Уровень:** ★★☆ · **Время:** ~40 мин

**Цель.** Две реплики сервиса за Nginx, видно, что запросы распределяются.

**Требования.**

- сервис `app` на образе `traefik/whoami` (в ответе — имя контейнера), **2 реплики**;
- `nginx` слушает `localhost:8080` и проксирует в `app`;
- наружу открыт только Nginx;
- Nginx передаёт `X-Real-IP` и `X-Forwarded-For`.

**Проверка.**

```bash
docker compose up -d
for i in 1 2 3 4; do curl -s localhost:8080 | grep Hostname; done   # имена чередуются
```

??? tip "Подсказка"
    `deploy.replicas` в compose создаёт несколько контейнеров с одним DNS-именем. Встроенный DNS Docker
    отдаёт все их IP, а Nginx при старте добавит каждый адрес в upstream.

??? success "Решение"
    ```yaml
    # compose.yaml
    services:
      app:
        image: traefik/whoami:v1.10
        deploy:
          replicas: 2
      nginx:
        image: nginx:1.27-alpine
        volumes:
          - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
        ports: ["8080:80"]
        depends_on: [app]
    ```

    ```nginx
    # nginx.conf
    upstream app {
        server app:80;
    }
    server {
        listen 80;
        location / {
            proxy_pass http://app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
    ```

    **Подвох.** Nginx резолвит `app` один раз при старте. Масштабируешь `docker compose up -d --scale app=3` —
    Nginx про новую реплику не узнает, пока не сделать `docker compose restart nginx`. В проде для
    динамики используют `resolver` + переменную в `proxy_pass` или балансировщик с service discovery.

---

## Kubernetes (kind)

### Задача 6. Свой кластер в kind

**Уровень:** ★☆☆ · **Время:** ~30 мин

**Цель.** Локальный кластер из 3 узлов и первый деплой.

**Требования.**

- kind: 1 control-plane + 2 worker, имя кластера `lab`;
- Deployment `web` (`nginx:1.27-alpine`) на 3 реплики и Service типа ClusterIP;
- открыть в браузере через `port-forward`;
- посмотреть, по каким узлам разошлись поды.

**Проверка.**

```bash
kubectl get nodes
kubectl get pods -o wide            # колонка NODE
kubectl port-forward svc/web 8080:80 &  curl -s localhost:8080 | head -3
```

??? success "Решение"
    ```yaml
    # kind.yaml
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
      - role: control-plane
      - role: worker
      - role: worker
    ```

    ```bash
    kind create cluster --name lab --config kind.yaml
    kubectl create deployment web --image=nginx:1.27-alpine --replicas=3
    kubectl expose deployment web --port=80
    kubectl get pods -o wide
    ```

    Удалить: `kind delete cluster --name lab`. Образ, собранный локально, в kind загружают так:
    `kind load docker-image hello:1.0 --name lab` — кластер не видит образы Docker хоста.

---

### Задача 7. Production-ready манифест Deployment

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Написать манифест руками (без `kubectl create`) со всем, что ждут на ревью.

**Требования** (образ `nginxinc/nginx-unprivileged:1.27-alpine`, порт 8080):

- 2 реплики, `RollingUpdate` с `maxUnavailable: 0`;
- readiness и liveness пробы на `/`;
- requests и limits;
- `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `drop: [ALL]`;
- под не падает из-за read-only файловой системы;
- Service на порт 80 → 8080.

**Проверка.**

```bash
kubectl apply -f deploy.yaml
kubectl get pods                                         # 1/1 Running, без рестартов
kubectl exec deploy/web -- touch /etc/x                  # Read-only file system
kubectl port-forward svc/web 8080:80 & curl -sI localhost:8080 | head -1
```

??? tip "Подсказка"
    nginx пишет pid и временные файлы в `/tmp`. При read-only корне туда нужен `emptyDir`.

??? success "Решение"
    ```yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: web }
    spec:
      replicas: 2
      strategy:
        type: RollingUpdate
        rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
      selector:
        matchLabels: { app: web }
      template:
        metadata:
          labels: { app: web }
        spec:
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: nginx
              image: nginxinc/nginx-unprivileged:1.27-alpine
              ports: [{ name: http, containerPort: 8080 }]
              readinessProbe: { httpGet: { path: /, port: http }, periodSeconds: 5 }
              livenessProbe:  { httpGet: { path: /, port: http }, periodSeconds: 10 }
              resources:
                requests: { cpu: 50m, memory: 32Mi }
                limits:   { memory: 64Mi }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: [ALL] }
              volumeMounts: [{ name: tmp, mountPath: /tmp }]
          volumes: [{ name: tmp, emptyDir: {} }]
    ---
    apiVersion: v1
    kind: Service
    metadata: { name: web }
    spec:
      selector: { app: web }
      ports: [{ port: 80, targetPort: http }]
    ```

    **Почему limit только на память.** CPU limit вызывает троттлинг даже при свободном узле;
    многие команды ставят на CPU только request. Память — несжимаемый ресурс, limit нужен.

---

### Задача 8. ConfigMap: env против файла

**Уровень:** ★★☆ · **Время:** ~30 мин

**Цель.** Увидеть разницу: как приложение получает изменения ConfigMap через переменную и через файл.

**Требования.**

- ConfigMap `app-config` с ключом `GREETING=hello`;
- под `busybox`, который каждые 5 секунд печатает `$GREETING` **и** содержимое смонтированного файла;
- поменять значение на `bye` и понаблюдать за логами 2 минуты;
- объяснить, что увидел, и как заставить поды подхватить изменение.

**Проверка.**

```bash
kubectl logs -f deploy/cfg-demo
kubectl patch configmap app-config -p '{"data":{"GREETING":"bye"}}'
```

??? success "Решение"
    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata: { name: app-config }
    data: { GREETING: hello }
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: cfg-demo }
    spec:
      selector: { matchLabels: { app: cfg-demo } }
      template:
        metadata: { labels: { app: cfg-demo } }
        spec:
          containers:
            - name: demo
              image: busybox:1.37
              command: ["sh", "-c", "while true; do echo env=$GREETING file=$(cat /cfg/GREETING); sleep 5; done"]
              envFrom: [{ configMapRef: { name: app-config } }]
              volumeMounts: [{ name: cfg, mountPath: /cfg }]
          volumes: [{ name: cfg, configMap: { name: app-config } }]
    ```

    **Что видно.** `env=hello` не меняется никогда — переменные окружения читаются один раз при старте.
    `file=` меняется на `bye` примерно через минуту — kubelet обновляет смонтированный том
    (**но не при `subPath`!**). Подхватить в env: `kubectl rollout restart deploy/cfg-demo`, а в Helm —
    аннотация `checksum/config` с хэшем ConfigMap в шаблоне пода.

---

### Задача 9. Zero-trust: NetworkPolicy в kind

**Уровень:** ★★★ · **Время:** ~1 ч

**Цель.** Запретить весь трафик в namespace и разрешить только нужный — и доказать это проверками.

**Требования.**

- kind **без** стандартного CNI + Calico (стандартный kindnet NetworkPolicy игнорирует);
- namespace `shop`: `api` (nginx) и `client` (curl);
- `default-deny-all` (ingress и egress), затем разрешить: `client → api:80` и DNS;
- проверить: `client → api` работает, под из `default` → `api` — таймаут, `api` → интернет — таймаут.

**Проверка.** Таблица из трёх проверок «откуда → куда → ожидание → результат».

??? tip "Подсказка"
    В конфиге kind: `networking: { disableDefaultCNI: true, podSubnet: 192.168.0.0/16 }`, потом
    `kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml`.
    Пока Calico не встал, узлы `NotReady`. Не забудь про DNS — без него `curl api` не разрезолвит имя.

??? success "Решение"
    ```yaml
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata: { name: default-deny-all, namespace: shop }
    spec:
      podSelector: {}
      policyTypes: [Ingress, Egress]
    ---
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata: { name: allow-dns, namespace: shop }
    spec:
      podSelector: {}
      policyTypes: [Egress]
      egress:
        - to:
            - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
              podSelector: { matchLabels: { k8s-app: kube-dns } }
          ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    ---
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata: { name: api-from-client, namespace: shop }
    spec:
      podSelector: { matchLabels: { app: api } }
      policyTypes: [Ingress]
      ingress:
        - from: [{ podSelector: { matchLabels: { app: client } } }]
          ports: [{ port: 80 }]
    ---
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata: { name: client-to-api, namespace: shop }
    spec:
      podSelector: { matchLabels: { app: client } }
      policyTypes: [Egress]
      egress:
        - to: [{ podSelector: { matchLabels: { app: api } } }]
          ports: [{ port: 80 }]
    ```

    Нужны **обе** стороны: egress у клиента и ingress у сервера — default-deny закрыл обе.
    Заблокированный запрос — таймаут, а не `Connection refused`: Calico молча отбрасывает пакеты.
    Подробно — [Диплом: zero-trust](diploma-k8s.md).

---

### Задача 10. Почини три сломанных пода

**Уровень:** ★★☆ · **Время:** ~30 мин

**Цель.** Найти причину по симптому — не глядя в манифесты, только через kubectl.

```bash
kubectl run broken-1 --image=nginx:1.27-alpne
kubectl run broken-2 --image=busybox:1.37 -- sh -c "echo starting; exit 1"
kubectl run broken-3 --image=nginx:1.27-alpine --overrides='{"spec":{"containers":[{"name":"broken-3","image":"nginx:1.27-alpine","resources":{"requests":{"cpu":"100"}}}]}}'
```

**Требования.** Для каждого: статус, команда, которой нашёл причину, причина, исправление.

??? tip "Подсказка"
    Три главные команды: `kubectl get pods` (статус), `kubectl describe pod` (секция Events внизу),
    `kubectl logs` (и `--previous` для упавшего контейнера).

??? success "Решение"
    | Под | Статус | Где видно | Причина |
    |---|---|---|---|
    | `broken-1` | `ImagePullBackOff` | `describe` → Events: `Failed to pull image ... not found` | опечатка в теге `alpne` |
    | `broken-2` | `CrashLoopBackOff` | `logs broken-2 --previous` → `starting`; `describe` → `Exit Code: 1` | процесс сам завершается с ошибкой |
    | `broken-3` | `Pending` | `describe` → Events: `0/3 nodes are available: 3 Insufficient cpu` | request 100 CPU — такого узла нет |

    Порядок диагностики пода: **статус → Events → логи (в т.ч. `--previous`) → `kubectl get events
    --sort-by=.lastTimestamp`**. `Pending` — это про планирование (ресурсы, taints, affinity, PVC),
    `CrashLoopBackOff` — про само приложение, `ImagePullBackOff` — про образ и доступ к реестру.

---

### Задача 11. HPA под нагрузкой

**Уровень:** ★★★ · **Время:** ~1 ч

**Цель.** Включить автомасштабирование по CPU и увидеть его в работе.

**Требования.**

- metrics-server в kind (`kubectl top pods` работает);
- Deployment `php-apache` (образ `registry.k8s.io/hpa-example`, request CPU 200m) + Service;
- HPA: 1–5 реплик, цель 50 % CPU;
- нагрузка из пода с `wget` в цикле; записать, через сколько выросли реплики и через сколько вернулись.

**Проверка.**

```bash
kubectl get hpa php-apache -w
kubectl run load --rm -it --image=busybox:1.37 -- sh -c "while true; do wget -q -O- http://php-apache; done"
```

??? tip "Подсказка"
    В kind у kubelet самоподписанный сертификат — metrics-server нужно запустить с
    `--kubelet-insecure-tls`.

??? success "Решение"
    ```bash
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl -n kube-system patch deploy metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

    kubectl create deployment php-apache --image=registry.k8s.io/hpa-example
    kubectl set resources deploy php-apache --requests=cpu=200m
    kubectl expose deploy php-apache --port=80
    kubectl autoscale deploy php-apache --cpu-percent=50 --min=1 --max=5
    ```

    Рост — 30–60 с (сбор метрик + цикл HPA 15 с), уменьшение — ~5 мин (окно стабилизации
    scale-down по умолчанию 300 с). Без `requests` HPA показывает `<unknown>`: утилизация считается
    от request. Сравни с [нагрузочным тестом диплома](diploma-momo-store.md).

---

### Задача 12. CronJob с данными на диске

**Уровень:** ★★☆ · **Время:** ~40 мин

**Цель.** Периодическая задача, которая пишет в постоянное хранилище, и её ручной запуск.

**Требования.**

- PVC на 100Mi;
- CronJob каждую минуту дописывает дату в `/data/log.txt`;
- одновременно не больше одного запуска; хранить 3 успешных и 1 неудачный Job;
- запустить задачу вручную, не дожидаясь расписания;
- прочитать файл, не дожидаясь следующего запуска.

??? success "Решение"
    ```yaml
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      resources: { requests: { storage: 100Mi } }
    ---
    apiVersion: batch/v1
    kind: CronJob
    metadata: { name: stamp }
    spec:
      schedule: "*/1 * * * *"
      concurrencyPolicy: Forbid
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 1
      jobTemplate:
        spec:
          backoffLimit: 2
          template:
            spec:
              restartPolicy: OnFailure
              containers:
                - name: stamp
                  image: busybox:1.37
                  command: ["sh", "-c", "date >> /data/log.txt; tail -3 /data/log.txt"]
                  volumeMounts: [{ name: data, mountPath: /data }]
              volumes: [{ name: data, persistentVolumeClaim: { claimName: data } }]
    ```

    ```bash
    kubectl create job --from=cronjob/stamp manual-1
    kubectl logs job/manual-1
    ```

    В kind PVC обслуживает local-path-provisioner (StorageClass `standard`). `ReadWriteOnce` — том
    монтируется только на один узел: Job'ы, попавшие на другой узел, ждут в `Pending`/`ContainerCreating`.

---

## Helm

### Задача 13. Чарт для своего сервиса

**Уровень:** ★★☆ · **Время:** ~1,5 ч

**Цель.** Упаковать сервис из задачи 1 в Helm-чарт и пройти цикл install → upgrade → rollback.

**Требования.**

- чарт `hello` (из `helm create` — убрать лишнее: ingress, serviceaccount, tests);
- образ `hello:1.0` загружен в kind; пробы на `/health`; resources;
- `values-dev.yaml` (1 реплика) и `values-prod.yaml` (3 реплики, больше ресурсов);
- `helm lint` и `helm template` без ошибок;
- установить с dev, обновить на prod, откатиться на ревизию 1.

**Проверка.**

```bash
helm history hello                       # 3 ревизии: install, upgrade, rollback
kubectl get deploy hello -o jsonpath='{.spec.replicas}'   # после отката — 1
```

??? success "Решение"
    ```bash
    kind load docker-image hello:1.0 --name lab
    helm create hello && cd hello
    rm -rf templates/ingress.yaml templates/serviceaccount.yaml templates/hpa.yaml templates/tests
    # deployment.yaml: убрать serviceAccountName; values.yaml: image.repository=hello, tag=1.0,
    # pullPolicy=IfNotPresent, service.port=8080, probes path=/health
    helm lint . && helm template hello . -f values-dev.yaml | less

    helm install hello . -f values-dev.yaml
    helm upgrade hello . -f values-prod.yaml
    helm rollback hello 1
    ```

    `pullPolicy: IfNotPresent` обязателен — иначе kubelet пойдёт за `hello:1.0` в Docker Hub.
    Подробнее о шаблонах — [Практикум Helm](helm-practice.md).

---

## Terraform

### Задача 14. Terraform без облака: провайдер Docker

**Уровень:** ★☆☆ · **Время:** ~40 мин

**Цель.** Отработать цикл `init → plan → apply → destroy` и работу со state без затрат.

**Требования.**

- провайдер `kreuzwerker/docker`;
- образ `nginx:1.27-alpine` и контейнер `tf-web`, внешний порт — переменная (по умолчанию 8081);
- output с URL;
- `terraform state list`, `terraform state show` для контейнера;
- поменять порт и посмотреть в plan: обновление на месте или пересоздание?

??? tip "Подсказка"
    Если `registry.terraform.io` недоступен — зеркало Yandex Cloud
    (см. [Диплом: Terraform](diploma-terraform.md)).

??? success "Решение"
    ```hcl
    terraform {
      required_providers {
        docker = { source = "kreuzwerker/docker", version = "~> 3.0" }
      }
    }

    provider "docker" {}

    variable "port" {
      type    = number
      default = 8081
    }

    resource "docker_image" "nginx" {
      name         = "nginx:1.27-alpine"
      keep_locally = true
    }

    resource "docker_container" "web" {
      name  = "tf-web"
      image = docker_image.nginx.image_id
      ports {
        internal = 80
        external = var.port
      }
    }

    output "url" {
      value = "http://localhost:${var.port}"
    }
    ```

    Смена порта — `-/+ must be replaced`: порты контейнера нельзя поменять на лету, Terraform пересоздаёт
    ресурс. Всегда читай в plan символы `~` (на месте) и `-/+` (пересоздание) — для БД или кластера
    это разница между «поменяли настройку» и «потеряли данные».

---

### Задача 15. Модуль и for_each

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Вынести контейнер из задачи 14 в модуль и создать три экземпляра.

**Требования.**

- модуль `modules/web` с переменными `name`, `port`, output `url`;
- в корне — `for_each` по карте `{ a = 8081, b = 8082, c = 8083 }`;
- output — карта всех URL;
- удалить `b` из карты: plan должен удалить **только** `b`;
- объяснить, что было бы с `count`.

??? success "Решение"
    ```hcl
    # modules/web/main.tf
    terraform {
      required_providers { docker = { source = "kreuzwerker/docker" } }
    }
    variable "name" { type = string }
    variable "port" { type = number }

    resource "docker_container" "this" {
      name  = var.name
      image = "nginx:1.27-alpine"
      ports {
        internal = 80
        external = var.port
      }
    }
    output "url" { value = "http://localhost:${var.port}" }
    ```

    ```hcl
    # main.tf
    locals { sites = { a = 8081, b = 8082, c = 8083 } }

    module "web" {
      source   = "./modules/web"
      for_each = local.sites
      name     = "web-${each.key}"
      port     = each.value
    }

    output "urls" { value = { for k, m in module.web : k => m.url } }
    ```

    С `for_each` адреса ресурсов — `module.web["a"]`, удаление `b` трогает только его.
    С `count` адреса — индексы `[0] [1] [2]`: удалишь средний — `[2]` станет `[1]`, и Terraform
    пересоздаст «сдвинувшиеся» ресурсы. Поэтому для именованных сущностей — `for_each`.

---

## CI/CD

### Задача 16. GitHub Actions: тесты и образ по тегу

**Уровень:** ★★☆ · **Время:** ~1 ч

**Цель.** Пайплайн для сервиса из задачи 1: проверки на каждый push, образ в GHCR — только на тег.

**Требования.**

- на push и pull request: `go vet`, `go test -race`;
- на тег `v*`: сборка и push в `ghcr.io/<user>/<repo>:<версия без v>`;
- без личных токенов — только `GITHUB_TOKEN`;
- кэш слоёв Docker между запусками.

??? success "Решение"
    ```yaml
    # .github/workflows/ci.yml
    name: ci
    on:
      push:
        branches: [main]
        tags: ["v*"]
      pull_request:

    jobs:
      test:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: actions/setup-go@v5
            with: { go-version: "1.25" }
          - run: go vet ./...
          - run: go test -race ./...

      image:
        if: startsWith(github.ref, 'refs/tags/v')
        needs: test
        runs-on: ubuntu-latest
        permissions:
          contents: read
          packages: write
        steps:
          - uses: actions/checkout@v4
          - uses: docker/setup-buildx-action@v3
          - uses: docker/login-action@v3
            with:
              registry: ghcr.io
              username: ${{ github.actor }}
              password: ${{ secrets.GITHUB_TOKEN }}
          - id: v
            run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          - uses: docker/build-push-action@v6
            with:
              push: true
              tags: ghcr.io/${{ github.repository }}:${{ steps.v.outputs.version }}
              cache-from: type=gha
              cache-to: type=gha,mode=max
    ```

    `permissions: packages: write` нужен, чтобы `GITHUB_TOKEN` мог писать в GHCR. Имя репозитория
    в GHCR должно быть в нижнем регистре. Сравни с [CI диплома](diploma-cicd.md): там build once —
    образ на тег не пересобирается, а перетегируется.

---

## Мониторинг

### Задача 17. Алерты в Prometheus

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Добавить в стек из задачи 4 правила алертов и увидеть, как алерт проходит `Pending → Firing`.

**Требования.**

- `InstanceDown`: таргет недоступен дольше 1 минуты;
- `HighCPU`: загрузка CPU узла выше 80 % дольше 2 минут;
- у алертов `severity` и понятный `summary` с именем инстанса;
- уронить node-exporter и пронаблюдать в `/alerts`.

??? success "Решение"
    ```yaml
    # alerts.yml
    groups:
      - name: basic
        rules:
          - alert: InstanceDown
            expr: up == 0
            for: 1m
            labels: { severity: critical }
            annotations:
              summary: "{{ $labels.job }} ({{ $labels.instance }}) недоступен"
          - alert: HighCPU
            expr: 100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100 > 80
            for: 2m
            labels: { severity: warning }
            annotations:
              summary: "CPU {{ $labels.instance }}: {{ $value | humanize }}%"
    ```

    В `prometheus.yml`: `rule_files: [/etc/prometheus/alerts.yml]` + смонтировать файл. Проверка
    синтаксиса: `docker compose exec prometheus promtool check rules /etc/prometheus/alerts.yml`.
    `docker compose stop node-exporter` → через ~15 с `Pending`, через 1 мин `Firing`. `for` защищает
    от ложных срабатываний на кратковременный сбой. Отправка уведомлений — Alertmanager.

---

## Bash и Linux

### Задача 18. Скрипт проверки доступности сайтов

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Скрипт для cron или CI: проверяет список URL и возвращает код выхода.

**Требования.**

- URL — из файла (по одному в строке, `#` — комментарий);
- таймаут 5 с, до 3 попыток с паузой;
- вывод: `OK  200  0.123s  https://...` / `FAIL 000 https://...`;
- код выхода 1, если хоть один URL недоступен;
- `set -euo pipefail`, `shellcheck` без замечаний.

??? success "Решение"
    ```bash
    #!/usr/bin/env bash
    set -euo pipefail

    file="${1:?usage: $0 urls.txt}"
    failed=0

    while IFS= read -r url || [ -n "$url" ]; do
      [[ -z "$url" || "$url" == \#* ]] && continue
      result=$(curl -s -o /dev/null --max-time 5 --retry 2 --retry-delay 2 --retry-all-errors \
               -w '%{http_code} %{time_total}' "$url" || true)
      code=${result%% *}
      if [[ "$code" =~ ^[23] ]]; then
        printf 'OK   %s  %ss  %s\n' "$code" "${result#* }" "$url"
      else
        printf 'FAIL %s  %s\n' "${code:-000}" "$url"
        failed=1
      fi
    done < "$file"

    exit "$failed"
    ```

    `|| [ -n "$url" ]` — чтобы не потерять последнюю строку без перевода строки. `|| true` после curl —
    иначе `set -e` оборвёт скрипт на первом недоступном URL. `--retry-all-errors` — повторять и при
    ошибках соединения, а не только при 5xx.

---

### Задача 19. Диск полон, а файлов нет

**Уровень:** ★★★ · **Время:** ~30 мин

**Цель.** Классика собеседований: `df` показывает занятое место, а `du` его не находит.

```bash
docker run -it --rm ubuntu:24.04 bash
apt-get update -qq && apt-get install -y -qq lsof procps
dd if=/dev/zero of=/tmp/big.log bs=1M count=500
tail -f /tmp/big.log > /dev/null &
rm /tmp/big.log
df -h /tmp ; du -sh /tmp
```

**Требования.** Объяснить, почему место не освободилось; найти процесс; освободить место **без**
перезапуска процесса.

??? success "Решение"
    Файл удалён из каталога (удалена ссылка), но процесс `tail` держит его открытым — данные живут, пока
    открыт дескриптор. `du` считает файлы в дереве каталогов, `df` — занятые блоки файловой системы.

    ```bash
    lsof +L1                                   # открытые файлы с 0 ссылок: COMMAND, PID, FD
    ls -l /proc/*/fd 2>/dev/null | grep deleted
    : > /proc/<PID>/fd/<FD>                    # обнулить файл через дескриптор — место освобождается
    ```

    В проде так бывает с логами: logrotate удалил файл, а сервис продолжает писать в старый дескриптор.
    Правильно — `copytruncate` или сигнал сервису переоткрыть логи (`nginx -s reopen`, `SIGHUP`).

---

## Ansible

### Задача 20. Идемпотентный playbook

**Уровень:** ★★☆ · **Время:** ~1 ч

**Цель.** Playbook, который при повторном запуске ничего не меняет (`changed=0`).

**Требования** (целевой хост — контейнер `python:3.12-slim`, в нём уже есть Python):

- подключение к контейнеру без SSH — connection-плагин Docker;
- установить пакет `curl`; создать пользователя `deploy`; каталог `/opt/app` владельца `deploy`;
- из шаблона создать `/opt/app/config.ini` с переменной `env`;
- строка `MaxSessions 10` в `/etc/app.conf` — добавить, не дублируя;
- второй запуск: `changed=0`.

```bash
docker run -d --name target python:3.12-slim sleep infinity
ansible-galaxy collection install community.docker
```

??? success "Решение"
    ```ini
    # inventory.ini
    [lab]
    target ansible_connection=community.docker.docker ansible_python_interpreter=/usr/local/bin/python3
    ```

    ```yaml
    # site.yml
    - hosts: lab
      become: false
      vars:
        env: dev
      tasks:
        - name: curl
          ansible.builtin.apt: { name: curl, state: present, update_cache: true, cache_valid_time: 3600 }
        - name: user deploy
          ansible.builtin.user: { name: deploy, system: true }
        - name: app dir
          ansible.builtin.file: { path: /opt/app, state: directory, owner: deploy, mode: "0755" }
        - name: config
          ansible.builtin.template: { src: config.ini.j2, dest: /opt/app/config.ini, owner: deploy, mode: "0640" }
        - name: max sessions
          ansible.builtin.lineinfile: { path: /etc/app.conf, line: "MaxSessions 10", create: true }
    ```

    `config.ini.j2`: `[app]` и `env = {{ env }}`. Запуск: `ansible-playbook -i inventory.ini site.yml`
    (дважды). `cache_valid_time` — иначе `apt update_cache` будет `changed` на каждом запуске. Модули
    `command`/`shell` не идемпотентны сами по себе — для них нужны `creates:` или `changed_when:`.

---

## Безопасность

### Задача 21. Trivy: образ и конфигурация

**Уровень:** ★★☆ · **Время:** ~40 мин

**Цель.** Найти уязвимости в образе и ошибки конфигурации в манифестах — и исправить.

**Требования.**

- просканировать `python:3.9` и `python:3.12-slim`: сравнить число CRITICAL/HIGH;
- оставить только исправимые (`--ignore-unfixed`) — сколько осталось?
- `trivy config` по Dockerfile из задачи 3 (плохому) и манифесту из задачи 7;
- добиться: 0 исправимых CRITICAL в образе, 0 HIGH в манифесте.

??? success "Решение"
    ```bash
    trivy image --severity CRITICAL,HIGH python:3.9 | tail -3
    trivy image --severity CRITICAL,HIGH --ignore-unfixed python:3.12-slim
    trivy config --severity HIGH,CRITICAL ./bad/      # Dockerfile: root, latest-подобные теги, apt без --no-install-recommends
    trivy config ./k8s/deploy.yaml                    # securityContext, limits, readOnlyRootFilesystem...
    ```

    Основные рычаги: свежая и **минимальная** база (slim/alpine/distroless/scratch), `apk/apt upgrade`
    при сборке, пересборка образов по расписанию — CVE появляются и в старых образах. В CI — блокировать
    только исправимые CRITICAL, иначе пайплайн будет красным из-за того, что исправить нельзя.

---

## SRE

### Задача 22. Runbook и postmortem

**Уровень:** ★★☆ · **Время:** ~1 ч

**Цель.** Написать два документа, которые пишут на работе после настоящих инцидентов.

**Требования.**

1. **Runbook** для алерта «HighErrorRate: доля 5xx API > 5 % за 5 минут»: что значит, как проверить,
   частые причины, шаги устранения, когда эскалировать.
2. **Blameless postmortem** по инциденту из диплома: сборки падали из-за таймаутов `gcr.io`
   ([журнал проблем](diploma-troubleshooting.md), № 23): хронология, влияние, причина, что помогло,
   action items с владельцами.

??? success "Решение"
    **Runbook (скелет).**

    1. *Что значит:* пользователи получают ошибки на ≥5 % запросов API.
    2. *Проверить:* дашборд R.E.D. — ошибки на всех маршрутах или одном; когда начались; был ли деплой
       (`helm history`).
    3. *Частые причины → действие:* свежий деплой → `helm rollback`; поды не Ready / рестарты →
       `kubectl describe`, `logs --previous`; зависимость (БД, внешний API) недоступна → её статус;
       упор в ресурсы → HPA, лимиты.
    4. *Эскалация:* > 15 минут без улучшения или > 20 % ошибок — дежурный разработчик сервиса.

    **Postmortem (скелет).** Резюме (2–3 строки) → Влияние (сколько релизов задержано, на сколько) →
    Хронология с временем → Причина (сеть раннеров нестабильно достаёт `gcr.io` — внешняя зависимость
    в критическом пути сборки) → Что сработало / что нет (Retry помогал не всегда) → Action items:
    базовый образ `scratch` (сделано), база Trivy с `ghcr.io` (сделано), ревизия всех внешних
    зависимостей CI (владелец, срок). Без поиска виноватых: «что в системе позволило этому случиться».

---

## GitOps

### Задача 23. Argo CD в kind

**Уровень:** ★★★ · **Время:** ~1,5 ч

**Цель.** Деплой из git: изменение в репозитории само попадает в кластер, ручные правки откатываются.

**Требования.**

- Argo CD в kind, доступ к UI через port-forward;
- репозиторий с манифестом из задачи 7 в каталоге `k8s/`;
- Application с `automated: { prune: true, selfHeal: true }`;
- изменить `replicas` в git → кластер подтянул изменение;
- `kubectl scale` руками → Argo CD вернул значение из git.

??? success "Решение"
    ```bash
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
    kubectl -n argocd port-forward svc/argocd-server 8443:443
    ```

    ```yaml
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata: { name: web, namespace: argocd }
    spec:
      project: default
      source:
        repoURL: https://github.com/<user>/<repo>.git
        targetRevision: main
        path: k8s
      destination:
        server: https://kubernetes.default.svc
        namespace: web
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
    ```

    Argo CD опрашивает git раз в ~3 минуты (быстрее — кнопка Refresh или webhook). `selfHeal` возвращает
    ручной `kubectl scale` почти сразу. Подробнее — [GitOps](gitops.md).
