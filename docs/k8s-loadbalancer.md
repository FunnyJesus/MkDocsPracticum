# LoadBalancer в Kubernetes

В Kubernetes **балансировка внешнего трафика на поды** решается на двух уровнях: **Service** (стабильная точка входа внутри кластера) и **Ingress** (внешний роутер по доменам/paths). Здесь разберём оба — и типы Service.

> Это продолжение «[Service](k8s.md#service)» и «[Ingress](k8s.md#http-ingress)» из основного конспекта, но глубже: какие бывают Service, когда брать LoadBalancer, а когда Ingress.

## Типы Service (спектр)

| Тип | Доступность | Пример | Когда брать |
|---|---|---|---|
| **ClusterIP** | только внутри кластера | внутренние сервисы (menu, order, redis) | стабильное имя для внутреннего общения |
| **NodePort** | наружу через порт ноды `30000-32767` | отладка, мини-тесты | быстрый доступ без облака |
| **LoadBalancer** | наружу через внешний IP провайдера | публичный сервис | когда нужен полноценный внешний балансировщик |
| **ExternalName** | DNS-алиас на внешнее имя | связка с внешним сервисом | переадресация на внешний CNAME |

> LoadBalancer — это фактически **ClusterIP + NodePort**, но провайдер облака (или MetalLB) сам выделяет внешний IP и подключает его к нодам.

## Service типа LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-ui
spec:
  type: LoadBalancer          # меняем тип на LoadBalancer
  selector:
    app: web-ui               # цепляемся к подам по метке
  ports:
    - port: 80                # порт, который слушает балансировщик
      targetPort: 8080        # порт пода (контейнера)
```

```bash
kubectl apply -f service-lb.yaml
kubectl get svc web-ui            # в столбце EXTERNAL-IP появится внешний адрес
kubectl get svc web-ui -o wide
```

**Что происходит:** кластер отдаёт запрос провайдеру → провайдер создаёт балансировщик → тот шлёт трафик на ноды/поды по метке `app: web-ui`. Kubernetes сам следит, чтобы балансировщик всегда указывал на живые поды.

> Порт `port` — это то, что слышит «снаружи». `targetPort` — реальный порт контейнера. Часто они различаются (контейнер слушает 8080, наружу отдаём 80).

## LoadBalancer vs NodePort vs ClusterIP

| Вопрос | ClusterIP | NodePort | LoadBalancer |
|---|---|---|---|
| Доступен снаружи кластера | ❌ | ✅ через порт ноды | ✅ через внешний IP |
| Требует облако/MetalLB | нет | нет | да (для внешнего IP) |
| Публичный стабильный IP | нет | нет (случайный порт ноды) | ✅ |
| Логика маршрутизации (по URL/домену) | нет | нет | ❌ (только L4) |
| Когда использовать | внутренние сервисы | тесты/отладка | один публичный сервис |

## LoadBalancer vs Ingress

| Вопрос | Service LoadBalancer | Ingress |
|---|---|---|
| Уровень | L4 (IP/порт) | L7 (HTTP/HTTPS) |
| Маршрутизация по доменам/путям | ❌ | ✅ |
| TLS/HTTPS | требует внешней настройки | ✅ (в правилах Ingress) |
| Один адрес на N сервисов | ❌ (по балансировщику на сервис) | ✅ (один ingress на много сервисов) |
| Grafana/API только по IP | подходит | избыточно |
| Несколько приложений по доменам | неудобно | идеально |

> **Золотое правило:** если внешнего доступа требует **один сервис без доменов** — хватит `type: LoadBalancer`. Если у тебя **несколько сервисов по разным доменам/путям с TLS** — нужен **Ingress** (он сам смотрит на LoadBalancer-сервис контроллера как на точку входа).

## Ingress как «продвинутый балансировщик»

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
spec:
  rules:
    - host: pizza.example.com
      http:
        paths:
          - path: /api/menu
            pathType: Prefix
            backend:
              service:
                name: menu-service
                port:
                  number: 8000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-ui
                port:
                  number: 80
```

* Ingress требует **ingress-controller** (nginx, traefik, haproxy).
* Контроллер — это обычный Deployment + LoadBalancer/NodePort Service, который и принимает весь трафик.
* Внутри уже можно раздавать запросы по `host` и `path` на разные backend-сервисы.

```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

## MetalLB (локальный LoadBalancer-провайдер)

Если кластер не в облаке (kind, bare metal), `type: LoadBalancer` не получит внешний IP автоматически — нужен **MetalLB**:

```yaml
# ConfigMap для MetalLB: диапазон IP, которые он будет раздавать
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  address-pools: |
    - name: default
      protocol: layer2
      addresses:
        - 192.168.1.200-192.168.1.250
```

> MetalLB эмулирует облачного провайдера: берёт IP из пула и начинает балансировать на него. Это позволяет использовать `type: LoadBalancer` в локальных/minikube/kind кластерах.

## kube-proxy и балансировка внутри кластера

Даже у обычного `ClusterIP` есть балансировка: **kube-proxy** на каждой ноде поддерживает правила, которые равномерно распределяют соединения между подами сервиса (в связке с `iptables`/`ipvs`).

* **iptables** — классический режим, каждое правило обрабатывается последовательно.
* **ipvs** — более производительный режим балансировки на уровне ядра, лучше для больших кластеров.

Выбор включается на уровне кластера/нод и для пользователя обычно невидим — главное понимать, что балансировка между подами обеспечивается не приложением, а самим Kubernetes.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `EXTERNAL-IP` висит `<pending>` | нет облачного провайдера / MetalLB | установить/настроить MetalLB, проверить пул IP |
| Внешний трафик есть, но сервис не отвечает | selector не совпадает с метками подов | проверить `kubectl get pods --show-labels` и `selector` |
| `port`/`targetPort` не совпадают | разнобой портов контейнера и сервиса | сверить реальный порт приложения с `targetPort` |
| Несколько сервисов хотят один порт 80 снаружи | LoadBalancer не умеет маршрутизацию L7 | перейти на Ingress (один вход, разные paths) |

## Best Practices

* **Внутренние сервисы — ClusterIP**, без лишнего внешнего доступа.
* **Один внешний сервис без домена — LoadBalancer.**
* **Несколько сервисов по доменам/paths с TLS — Ingress.**
* **Selector должен точно совпадать** с метками подов, иначе трафик никуда не пойдёт.
* **Не выставляйте наружу лишние порты** — только то, что действительно нужно.
* Балансировка между подами уже решается Kubernetes (kube-proxy) — не нужно «изобретать» её в приложении.

## Связка с материалами проекта

* Общая теория балансировки и алгоритмы (Round Robin, Least Connections) — [Балансировка нагрузки](load-balancing.md).
* Service и Ingress кратко — в [Kubernetes (теория)](k8s.md).
