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

Kubernetes-задания (6–13) делаются на проекте [k8s-platform-lab](https://github.com/FunnyJesus/k8s-platform-lab) и развивают его; остальные — самостоятельные.

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

## Kubernetes: k8s-platform-lab

Задания по Kubernetes делаются на твоём проекте
[k8s-platform-lab](https://github.com/FunnyJesus/k8s-platform-lab): каждое — **доработка проекта**, которая
остаётся в репозитории и в портфолио. Имена в проекте: кластер kind `platform-lab`, namespace, релиз и
Service — `my-app`, чарт `charts/my-app`; эндпоинты приложения — `/healthz`, `/readyz`, `/metrics`,
`/api/work?ms=N`, `/admin/ready`.

Перед каждым заданием:

```bash
cd ~/Documents/my_repo/k8s-platform-lab
git switch main && git pull
git switch -c task/<номер>-<кратко>
make up                     # кластер, ingress, metrics-server, деплой; уже поднят — не пересоздаёт
```

После: `make lint && make test`, коммит, pull request в `main` — CI прогонит e2e на живом kind.

---

### Задача 6. Разбери `make up` и добавь `make status`

**Уровень:** ★☆☆ · **Время:** ~30 мин

**Цель.** Понимать каждую строку своего Makefile и иметь одну команду для диагностики.

**Требования.**

- Ответить (в описании PR) на вопросы:
    1. Почему `deploy` зависит от `build`, а `build` — от `cluster`? Что будет при `make deploy` на пустой машине?
    2. Зачем `kind export kubeconfig` в цели `cluster` и в отдельной цели `kubeconfig`?
    3. Зачем цель `ingress` патчит контроллер `nodeSelector: ingress-ready`? Что сломается без патча?
    4. Зачем в начале цели `ingress` удаляются Job'ы admission-webhook?
    5. Что делают `--wait --timeout 5m` в `deploy` и что будет, если поды не станут Ready?
- Добавить цель `make status`: ноды, ресурсы релиза с узлами, последние 10 событий namespace, история
  Helm. Цель видна в `make help`.

**Проверка.**

```bash
make help | grep status
make status
```

??? tip "Подсказка"
    Ответы на 3 и 2 есть в README («Честные ограничения»). Для 4: какие поля Job можно менять после создания?

??? success "Решение"
    ```make
    status: ## состояние кластера и релиза
    	kubectl get nodes -o wide
    	kubectl -n $(NS) get deploy,pods,hpa,pdb,ingress -o wide
    	kubectl -n $(NS) get events --sort-by=.lastTimestamp | tail -10
    	helm -n $(NS) history $(RELEASE) --max 5
    ```

    И `status` — в `.PHONY`. Отступ в рецептах Makefile — **табуляция**, не пробелы.

    1. Цепочка гарантирует порядок: образ собирается, когда кластер есть, и загружается в него
       (`kind load`), а чарт ставится, когда образ уже в кластере. На пустой машине `make deploy` сам
       создаст кластер и соберёт образ — но без ingress и metrics-server (их ставит только `up`).
    2. kind пишет адрес API-сервера с портом Docker, который меняется после перезапуска Docker —
       старый kubeconfig перестаёт работать.
    3. Порты 80/443 проброшены `extraPortMappings` только на control-plane. Уедет контроллер на воркер —
       `localhost` перестанет отвечать.
    4. `spec.template` у Job неизменяем: повторный `kubectl apply` манифеста другой версии упадёт с
       `field is immutable`. Удаление делает цель повторяемой.
    5. Helm ждёт готовности ресурсов; не дождался за 5 минут — команда падает, **но релиз остаётся**
       в состоянии `failed` с новыми подами, отката нет (см. задачу 10).

---

### Задача 7. Pod Security `restricted` — включить по-настоящему

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** README проверяет совместимость с профилем `restricted` через `--dry-run`. Включи профиль
на namespace и докажи, что он работает.

**Требования.**

- namespace `my-app` создаётся **до** деплоя с метками `pod-security.kubernetes.io/enforce=restricted`
  и `warn=restricted` (цель `make namespace`, от неё зависит `deploy`);
- под, нарушающий профиль, не создаётся;
- `make deploy` и **`make test`** проходят.

**Проверка.**

```bash
kubectl get ns my-app --show-labels
kubectl run root-test -n my-app --image=nginx:1.27-alpine      # должен быть отклонён
make deploy && make test
```

??? tip "Подсказка"
    Под из `helm test` — тоже под в этом namespace. Посмотри на `templates/tests/test-endpoints.yaml`.
    И проверь, каким пользователем запускается образ `curlimages/curl`: `runAsNonRoot` не умеет
    проверять пользователя, заданного **именем**.

??? success "Решение"
    ```make
    namespace: ## namespace с Pod Security restricted
    	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
    	kubectl label namespace $(NS) --overwrite \
    		pod-security.kubernetes.io/enforce=restricted \
    		pod-security.kubernetes.io/warn=restricted

    deploy: build namespace ## поставить/обновить чарт
    ```

    `kubectl run root-test` → `Forbidden: violates PodSecurity "restricted:latest":
    allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile...`

    `make test` после включения профиля **падает** — под теста без `securityContext`. Исправление
    в `tests/test-endpoints.yaml`:

    ```yaml
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534          # числом: у curlimages/curl пользователь задан именем
        runAsGroup: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: curl
          image: curlimages/curl:8.11.1
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          # command / args — без изменений
    ```

    Без `runAsUser` числом под упадёт с `CreateContainerConfigError: container has runAsNonRoot and
    image has non-numeric user, cannot verify user is non-root`. Обнови README: профиль теперь
    **включён**, а не только проверен.

---

### Задача 8. `ADMIN_TOKEN` из Secret и ручной вывод пода из балансировки

**Уровень:** ★★☆ · **Время:** ~1 ч

**Цель.** В приложении есть `POST /admin/ready`, но он выключен, пока не задан `ADMIN_TOKEN`.
Передай токен безопасно и покажи разницу readiness и liveness на живом трафике.

**Требования.**

- в values: `admin.token` (пусто — Secret не создаётся, эндпоинт выключен) и `admin.existingSecret`;
- токен **не коммитится** — передаётся при деплое (добавь в Makefile переменную `HELM_EXTRA`);
- при смене токена поды перезапускаются;
- демонстрация: вывести один под из балансировки → он `0/1`, но **не перезапускается**, его нет в
  EndpointSlice, через Ingress его `instance` не отвечает; вернуть обратно.

**Проверка.**

```bash
TOKEN=$(openssl rand -hex 16)
make deploy HELM_EXTRA="--set admin.token=$TOKEN"
POD=$(kubectl -n my-app get pod -l app.kubernetes.io/name=my-app -o name | head -1)
kubectl -n my-app port-forward $POD 8000:8000 &
curl -X POST "localhost:8000/admin/ready?value=false&token=$TOKEN"
kubectl -n my-app get pods
for i in $(seq 10); do curl -s localhost/; echo; done
```

??? tip "Подсказка"
    `envFrom` принимает и `configMapRef`, и `secretRef`. Перезапуск при смене — та же техника, что
    `checksum/config` в твоём `deployment.yaml`.

??? success "Решение"
    ```yaml
    # values.yaml
    admin:
      token: ""            # только через --set, не коммитить
      existingSecret: ""   # или имя готового Secret с ключом ADMIN_TOKEN
    ```

    ```yaml
    # templates/secret.yaml
    {{- if and .Values.admin.token (not .Values.admin.existingSecret) }}
    apiVersion: v1
    kind: Secret
    metadata:
      name: {{ include "my-app.fullname" . }}-admin
      labels:
        {{- include "my-app.labels" . | nindent 4 }}
    type: Opaque
    stringData:
      ADMIN_TOKEN: {{ .Values.admin.token | quote }}
    {{- end }}
    ```

    В `deployment.yaml` — аннотация пода и второй источник `envFrom`:

    ```yaml
            checksum/admin: {{ .Values.admin.token | sha256sum }}
    ...
              envFrom:
                - configMapRef:
                    name: {{ include "my-app.fullname" . }}-config
                {{- if or .Values.admin.token .Values.admin.existingSecret }}
                - secretRef:
                    name: {{ .Values.admin.existingSecret | default (printf "%s-admin" (include "my-app.fullname" .)) }}
                {{- end }}
    ```

    В Makefile: `HELM_EXTRA ?=` и `$(HELM_EXTRA)` в конце команды `helm upgrade` цели `deploy`.

    Что видно: под `0/1 Running`, **RESTARTS не растёт** — `/readyz` отдаёт 503, а `/healthz` по-прежнему
    200. `kubectl -n my-app get endpointslices -l kubernetes.io/service-name=my-app -o yaml` — у его адреса
    `ready: false`. Через Ingress отвечает только второй `instance`. Вернуть: `value=true`.
    Так выводят под на отладку, не убивая его, — и так же ведёт себя под во время прогрева.

---

### Задача 9. Zero-trust: Calico и NetworkPolicy в чарте

**Уровень:** ★★★ · **Время:** ~1,5 ч

**Цель.** Под приложения принимает трафик только от ingress-nginx и от проверок, наружу не ходит никуда.

**Требования.**

- кластер с Calico: в стандартном CNI kind (kindnet) NetworkPolicy **игнорируются**;
- цель `make calico`, входит в `make up`;
- в чарте `networkPolicy.enabled`: вход в под приложения — только из namespace `ingress-nginx` и от
  пода `helm test`, на порт `http`; исходящий трафик — запрещён;
- `make test` проходит;
- таблица проверок: под из `default` → `my-app` (таймаут), Ingress → приложение (200),
  приложение → интернет (таймаут).

??? tip "Подсказка"
    Кластер придётся пересоздать (`make down && make up`) — CNI задаётся при создании. Пока Calico не
    встал, узлы `NotReady`. Посмотри на метки пода из `helm test`: какие из них совпадают с селектором
    приложения?

??? success "Решение"
    `configs/cluster.yaml` — в корень конфига:

    ```yaml
    networking:
      disableDefaultCNI: true
      podSubnet: 192.168.0.0/16      # пул Calico по умолчанию
    ```

    ```make
    calico: ## CNI Calico — нужен для NetworkPolicy
    	kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
    	kubectl -n kube-system rollout status ds/calico-node --timeout=300s

    up: cluster calico ingress metrics deploy  ## всё с нуля до рабочей ссылки
    ```

    ```yaml
    # templates/networkpolicy.yaml
    {{- if .Values.networkPolicy.enabled }}
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: {{ include "my-app.fullname" . }}
      labels:
        {{- include "my-app.labels" . | nindent 4 }}
    spec:
      podSelector:
        matchLabels:
          {{- include "my-app.selectorLabels" . | nindent 6 }}
      policyTypes: [Ingress, Egress]
      ingress:
        - from:
            - namespaceSelector:
                matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
            - podSelector:
                matchLabels:
                  app.kubernetes.io/instance: {{ .Release.Name }}
                  app.kubernetes.io/component: test
          ports:
            - port: http
      egress: []          # приложению наружу не нужно ничего
    {{- end }}
    ```

    **Ловушка.** Под теста получает метки через `my-app.labels`, а туда входят `selectorLabels` —
    политика приложения выберет и его: исходящий трафик теста к приложению будет запрещён, `make test`
    повиснет. Метки пода теста:

    ```yaml
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: test
    ```

    В CI кластер на kindnet (`cluster-ci.yaml`) — политики там не применяются, e2e пройдёт и без них.
    Это стоит записать в «Честные ограничения». Когда появится мониторинг в кластере (задача 13), добавь
    правило входа из namespace `monitoring`.

---

### Задача 10. Почини сломанный релиз

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Распознать четыре типичные поломки по симптомам и откатить релиз.

Перед началом — `helm -n my-app history my-app`. Ломай **по одной**, после каждой — диагностика и
`helm -n my-app rollback my-app`:

```bash
helm -n my-app upgrade my-app charts/my-app --reuse-values --set readinessProbe.httpGet.path=/nope
helm -n my-app upgrade my-app charts/my-app --reuse-values --set image.tag=nope
helm -n my-app upgrade my-app charts/my-app --reuse-values \
  --set resources.requests.cpu=10 --set resources.limits.cpu=10
helm -n my-app upgrade my-app charts/my-app --reuse-values \
  --set resources.requests.memory=30Mi --set resources.limits.memory=30Mi
```

**Требования.** Для каждой: статус пода, команда, где видна причина, причина. Отдельно ответь: почему
приложение через Ingress продолжало отвечать во время каждой поломки? Последний шаг — сделай так,
чтобы `make deploy` откатывался сам.

??? tip "Подсказка"
    `kubectl get pods`, `kubectl describe pod` (Events внизу), `kubectl logs --previous`,
    `kubectl get pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'`.

??? success "Решение"
    | Поломка | Статус | Где видно | Причина |
    |---|---|---|---|
    | readiness `/nope` | новый под `0/1 Running` | `describe`: `Readiness probe failed: HTTP probe failed with statuscode: 404` | проба на несуществующий путь |
    | `image.tag=nope` | `ErrImagePull` / `ImagePullBackOff` | `describe`: `pull access denied ... k8s-platform-lab:nope` | образа нет ни в kind, ни в Docker Hub |
    | `cpu=10` | `Pending` | `describe`: `Insufficient cpu` (+ taint control-plane) | такого узла нет |
    | память 30Mi | `CrashLoopBackOff` | `lastState.terminated.reason: OOMKilled` | Python + FastAPI не помещаются в 30 МиБ |

    Приложение отвечало, потому что rolling update не убирает старые поды, пока новые не Ready:
    у двух реплик `maxUnavailable` 25 % округляется вниз до 0.

    Автооткат: `--atomic` в `make deploy` (в Helm 4 он переименован в `--rollback-on-failure` —
    проверь `helm upgrade --help`). Не дождался готовности за `--timeout` — Helm сам вернёт прошлую ревизию.

---

### Задача 11. HPA: проверь утверждение README

**Уровень:** ★★★ · **Время:** ~1 ч

**Цель.** Как тестировщик: README утверждает, что потолок автоскейлинга — 4 реплики из-за
`nodeTaintsPolicy`, а в CI — 2. Проверь это экспериментом и приведи README в соответствие с реальностью.

**Требования.**

- найди в `values.yaml`, какое `nodeTaintsPolicy` стоит на самом деле, и предскажи результат;
- подними `autoscaling.maxReplicas` до 8 и дай нагрузку;
- посчитай поды по узлам, найди `Pending` (если есть) и их причину;
- исправь README (или values) так, чтобы описание совпадало с поведением.

**Проверка.**

```bash
make deploy HELM_EXTRA="--set autoscaling.maxReplicas=8"    # HELM_EXTRA — из задачи 8
BASE_URL=http://localhost ./scripts/generate-load.sh 180 16
kubectl -n my-app get hpa -w
kubectl -n my-app get pods -l app.kubernetes.io/name=my-app \
  -o custom-columns=NODE:.spec.nodeName,STATUS:.status.phase --no-headers | sort | uniq -c
```

??? tip "Подсказка"
    С `Ignore` узел control-plane — домен распределения, хотя поды на него не попадают из-за taint;
    с `Honor` узлы с непереносимыми taint из расчёта исключаются. Посчитай `maxSkew` для обоих случаев.

??? success "Решение"
    В `values.yaml` стоит `nodeTaintsPolicy: Honor` (добавлено коммитом «nodeTaintsPolicy в топологию»),
    а README описывает поведение `Ignore`:

    - **`Ignore`:** домены — control-plane (всегда 0 подов) и два воркера; `maxSkew: 2` → на воркере не
      больше 0 + 2 = 2 пода → потолок **4**. В CI (control-plane + 1 воркер) → **2**.
    - **`Honor`:** control-plane не считается; домены — только воркеры, и распределение ограничивает лишь
      разницу между ними (5/3, 4/4…). Потолок — `autoscaling.maxReplicas` и свободный CPU узлов
      (`requests.cpu: 100m` на под). В CI единственный воркер — единственный домен, ограничения нет.

    Значит, раздел «Честные ограничения» устарел: пункты про «потолок 4» и «в CI две реплики» нужно
    переписать (или вернуть `Ignore`, если ограничение было намеренным). Сколько реплик поднимет HPA,
    зависит от нагрузки и того, сколько CPU отдано Docker — запиши свои цифры в README.

---

### Задача 12. Синтетический мониторинг: CronJob в чарте

**Уровень:** ★★☆ · **Время:** ~45 мин

**Цель.** Раз в 5 минут проверять приложение «снаружи пода» — так, как его видит клиент.

**Требования.**

- `templates/cronjob.yaml` под флагом `synthetic.enabled`; расписание и путь — в values;
- `curl` к Service `my-app`, Job падает при ответе не 200; не больше одного запуска одновременно;
- хранить 3 успешных и 3 упавших Job;
- проходит профиль `restricted` (задача 7) и NetworkPolicy (задача 9);
- запустить вручную; сломать путь и увидеть упавший Job.

**Проверка.**

```bash
kubectl -n my-app create job --from=cronjob/my-app-synthetic synthetic-manual
kubectl -n my-app logs job/synthetic-manual
make deploy HELM_EXTRA="--set synthetic.path=/nope" && kubectl -n my-app create job --from=cronjob/my-app-synthetic synthetic-fail
kubectl -n my-app get jobs
```

??? success "Решение"
    ```yaml
    # values.yaml
    synthetic:
      enabled: true
      schedule: "*/5 * * * *"
      path: /readyz
    ```

    ```yaml
    # templates/cronjob.yaml
    {{- if .Values.synthetic.enabled }}
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: {{ include "my-app.fullname" . }}-synthetic
      labels:
        {{- include "my-app.labels" . | nindent 4 }}
    spec:
      schedule: {{ .Values.synthetic.schedule | quote }}
      concurrencyPolicy: Forbid
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 3
      jobTemplate:
        spec:
          backoffLimit: 0
          activeDeadlineSeconds: 60
          template:
            metadata:
              labels:
                app.kubernetes.io/instance: {{ .Release.Name }}
                app.kubernetes.io/component: synthetic
            spec:
              restartPolicy: Never
              securityContext:
                runAsNonRoot: true
                runAsUser: 65534
                runAsGroup: 65534
                seccompProfile: { type: RuntimeDefault }
              containers:
                - name: probe
                  image: curlimages/curl:8.11.1
                  args: ["-fsS", "--max-time", "5",
                         "http://{{ include "my-app.fullname" . }}:{{ .Values.service.port }}{{ .Values.synthetic.path }}"]
                  securityContext:
                    allowPrivilegeEscalation: false
                    readOnlyRootFilesystem: true
                    capabilities: { drop: [ALL] }
    {{- end }}
    ```

    Метки пода — **не** селектор приложения (иначе его зацепит NetworkPolicy приложения, как под теста).
    В NetworkPolicy из задачи 9 добавь в `from` ещё `podSelector` с `component: synthetic`.
    `curl -f` возвращает код 22 на ответ ≥ 400 → Job `Failed`. Следующий шаг — алерт на упавшие Job
    (`kube_job_status_failed` из kube-state-metrics, задача 13).

---

### Задача 13. Мониторинг в кластер: ServiceMonitor, дашборд и SLO-алерт

**Уровень:** ★★★ · **Время:** ~2 ч

**Цель.** Пункт из «Дальше по плану» README: Prometheus и Grafana в кластере, а не только в compose,
и алерт на твой SLO (p95 `/api/*` < 200 мс).

**Требования.**

- цель `make monitoring`: kube-prometheus-stack в namespace `monitoring` (без Alertmanager) — и она
  действительно выполняется (проверь `make -n monitoring`);
- в чарте `ServiceMonitor` и `PrometheusRule` — создаются, только если в кластере есть их CRD;
- дашборд `monitoring/grafana/dashboards/app-overview.json` подхватывается Grafana в кластере;
- алерты: `AppLatencySLOBreach` (p95 `/api/*` > 0,2 с в течение 5 мин) и `AppNoReadyInstances`;
- вызвать SLO-алерт нагрузкой с медленными запросами и увидеть его в Prometheus.

**Проверка.**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
open http://localhost:9090/targets           # my-app — UP
SLOW_EVERY=2 SLOW_MS=400 BASE_URL=http://localhost ./scripts/generate-load.sh 420 8
open http://localhost:9090/alerts            # AppLatencySLOBreach: Pending → Firing
```

??? tip "Подсказка"
    Дашборд писался под compose: проверь, какой `job` в его запросах и какой будет в кластере. И помни,
    что `{{ }}` в шаблонах Prometheus Helm тоже попытается выполнить.

??? success "Решение"
    ```make
    monitoring: ## Prometheus + Grafana в кластере
    	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    		--namespace monitoring --create-namespace --wait --timeout 10m \
    		--set alertmanager.enabled=false \
    		--set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    		--set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
    	kubectl -n monitoring create configmap app-overview-dashboard \
    		--from-file=monitoring/grafana/dashboards/app-overview.json --dry-run=client -o yaml | kubectl apply -f -
    	kubectl -n monitoring label configmap app-overview-dashboard grafana_dashboard=1 --overwrite
    ```

    **Обязательно добавь `monitoring` в `.PHONY`.** В проекте есть каталог `monitoring/`, и без `.PHONY`
    make считает цель выполненной — «файл» с таким именем уже существует: `make monitoring` ответит
    `'monitoring' is up to date` и ничего не сделает.

    `...NilUsesHelmValues=false` — иначе Prometheus берёт только ServiceMonitor и правила с меткой своего
    релиза. Порядок: сначала `make monitoring` (ставит CRD), потом `make deploy`.

    ```yaml
    # templates/servicemonitor.yaml
    {{- if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor" }}
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: {{ include "my-app.fullname" . }}
      labels:
        {{- include "my-app.labels" . | nindent 4 }}
    spec:
      selector:
        matchLabels:
          {{- include "my-app.selectorLabels" . | nindent 6 }}
      endpoints:
        - port: http
          path: /metrics
          interval: 15s
    {{- end }}
    ```

    ```yaml
    # templates/prometheusrule.yaml
    {{- if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1/PrometheusRule" }}
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: {{ include "my-app.fullname" . }}
      labels:
        {{- include "my-app.labels" . | nindent 4 }}
    spec:
      groups:
        - name: {{ include "my-app.fullname" . }}.slo
          rules:
            - alert: AppLatencySLOBreach
              expr: |
                histogram_quantile(0.95, sum by (le) (rate(
                  http_request_duration_seconds_bucket{namespace="{{ .Release.Namespace }}", path=~"/api/.*"}[5m]
                ))) > 0.2
              for: 5m
              labels: { severity: warning }
              annotations:
                summary: "p95 /api/* выше 200 мс — SLO нарушен"
            - alert: AppNoReadyInstances
              expr: sum(app_ready{namespace="{{ .Release.Namespace }}"}) < 1
              for: 1m
              labels: { severity: critical }
              annotations:
                summary: "нет ни одного готового инстанса"
    {{- end }}
    ```

    **Ловушки:**

    - В кластере метка `job` = имя Service (`my-app`), а дашборд фильтрует `job="app"` (так в compose).
      Замени в JSON на `job=~"app|my-app"` — дашборд заработает в обоих местах.
    - Шаблоны Prometheus вида `{{ $labels.instance }}` внутри чарта Helm выполнит сам и упадёт —
      экранируй: `{{ "{{" }} $labels.instance {{ "}}" }}`. В решении выше их нет специально.
    - С NetworkPolicy из задачи 9 разреши вход из namespace `monitoring` на порт `http`.

    Grafana: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`, пароль —
    `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`.
    Стек тяжёлый: дай Docker не меньше 6 ГБ памяти.

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
- `trivy config` по Dockerfile из задачи 3 (плохому) и по чарту `charts/my-app` из k8s-platform-lab;
- `trivy image` по образу проекта `k8s-platform-lab:dev`;
- добиться: 0 исправимых CRITICAL в образе, 0 HIGH в чарте.

??? success "Решение"
    ```bash
    trivy image --severity CRITICAL,HIGH python:3.9 | tail -3
    trivy image --severity CRITICAL,HIGH --ignore-unfixed python:3.12-slim
    trivy config --severity HIGH,CRITICAL ./bad/      # Dockerfile: root, latest-подобные теги, apt без --no-install-recommends
    trivy config ~/Documents/my_repo/k8s-platform-lab/charts/my-app   # Helm-чарт сканируется целиком
    trivy image --severity CRITICAL,HIGH --ignore-unfixed k8s-platform-lab:dev
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

### Задача 23. Argo CD для k8s-platform-lab

**Уровень:** ★★★ · **Время:** ~1,5 ч

**Цель.** Деплой из git: изменение в репозитории само попадает в кластер, ручные правки откатываются.

**Требования.**

- Argo CD в кластере `platform-lab`, доступ к UI через port-forward;
- Application смотрит на чарт `charts/my-app` твоего репозитория на GitHub, ветка `task/23-gitops`;
- релиз в отдельном namespace `my-app-gitops`, Ingress выключен (иначе конфликт с релизом
  `make deploy` за тот же путь `/`);
- `automated: { prune: true, selfHeal: true }`;
- изменить `config.LOG_LEVEL` в ветке → кластер подтянул; поправить ConfigMap руками → Argo CD вернул.

??? tip "Подсказка"
    Образ `k8s-platform-lab:dev` должен быть загружен в kind (`make build`) — Argo CD его не соберёт.
    Значения для чарта задаются в `spec.source.helm`.

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
    metadata: { name: my-app, namespace: argocd }
    spec:
      project: default
      source:
        repoURL: https://github.com/FunnyJesus/k8s-platform-lab.git
        targetRevision: task/23-gitops
        path: charts/my-app
        helm:
          valuesObject:
            image: { repository: k8s-platform-lab, tag: dev }
            ingress: { enabled: false }
      destination:
        server: https://kubernetes.default.svc
        namespace: my-app-gitops
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
    ```

    Проверка selfHeal:
    `kubectl -n my-app-gitops patch configmap my-app-config -p '{"data":{"LOG_LEVEL":"DEBUG"}}'` →
    через несколько секунд значение снова из git. Argo CD опрашивает git раз в ~3 минуты (быстрее —
    Refresh в UI или webhook). Если включил профиль `restricted` (задача 7) — повесь метки и на
    `my-app-gitops`. Подробнее — [GitOps](gitops.md).
