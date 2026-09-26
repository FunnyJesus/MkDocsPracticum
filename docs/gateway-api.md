# Gateway API — замена Ingress (и ingress-nginx)

> Как работает классический Ingress — [K8s LoadBalancer и Ingress](k8s-loadbalancer.md). Сам Nginx вне Kubernetes — [Nginx](nginx.md).

**Gateway API** — официальный стандарт Kubernetes (SIG Network) для входящего трафика в кластер. Он появился как «Ingress v2»: делает то же самое (домены, пути, TLS), но плюс канареечные релизы, заголовки, TCP/UDP/gRPC и разделение ответственности между командами — **без аннотаций, специфичных для конкретного контроллера**.

API-группа: `gateway.networking.k8s.io`. Основные ресурсы (`GatewayClass`, `Gateway`, `HTTPRoute`) стабильны (GA, `v1`) с 2023 года.

## Почему уходят с Ingress и ingress-nginx

**Ограничения самого Ingress:**

* Спецификация умеет только хост + путь + TLS. Всё остальное (редиректы, rewrite, таймауты, canary, CORS, rate limit) — **через аннотации**, и у каждого контроллера они свои. Переехать с nginx на Traefik = переписать все аннотации.
* Один объект на всё: и настройка балансировщика, и маршруты приложения. Нельзя нормально разделить права между платформенной командой и разработчиками.
* Только HTTP/HTTPS. TCP/UDP/gRPC — костылями через ConfigMap.

**ingress-nginx выводится из поддержки.** В ноябре 2025 года Kubernetes SIG Network объявил о завершении проекта **ingress-nginx** (community-контроллер `kubernetes/ingress-nginx`): поддержка «по возможности» до марта 2026, после этого — ни релизов, ни исправлений уязвимостей. Существующие установки продолжают работать, но новым кластерам рекомендуют Gateway API. Проверь актуальный статус в [блоге Kubernetes](https://kubernetes.io/blog/) перед решением.

!!! note "Не путать"
    `kubernetes/ingress-nginx` (community) и **NGINX Ingress Controller** от F5/NGINX Inc (`nginxinc/kubernetes-ingress`) — это **разные** проекты. У NGINX Inc для Gateway API есть отдельная реализация — **NGINX Gateway Fabric**.

## Ingress vs Gateway API

| | Ingress | Gateway API |
|---|---|---|
| Статус | заморожен, новых возможностей не будет | активно развивается |
| Расширенные функции | аннотации конкретного контроллера | в стандартной спецификации |
| Переносимость | низкая (аннотации) | высокая: одинаковый YAML для разных реализаций |
| Роли | один объект | Инфраструктура / кластер / приложение — разные ресурсы |
| Протоколы | HTTP(S) | HTTP, HTTPS, gRPC, TLS, TCP, UDP |
| Разделение трафика (canary) | аннотации (`canary-weight`) | `weight` в `backendRefs` |
| Маршрут в другом namespace | нет | да, с явным разрешением (`ReferenceGrant`) |

## Модель ресурсов и ролей

```
Провайдер инфраструктуры     GatewayClass    «какой контроллер» (Envoy, Cilium, NGINX…)
          │
Оператор кластера            Gateway         «точка входа»: порты, протоколы, TLS, кто может подключаться
          │
Разработчик приложения       HTTPRoute       «маршруты»: host/path → Service
          │
                             Service → Pods
```

| Ресурс | Кто создаёт | Аналог в мире Ingress |
|---|---|---|
| **GatewayClass** | ставится вместе с контроллером | `IngressClass` |
| **Gateway** | платформенная команда | сам ingress-controller + его Service LoadBalancer |
| **HTTPRoute** / `GRPCRoute` / `TLSRoute` / `TCPRoute` | команда приложения | объект `Ingress` |
| **ReferenceGrant** | владелец namespace-цели | — (разрешение ссылаться через namespace) |

Идея: разработчик **не может** случайно поменять порт или сертификат балансировщика, а платформенная команда не правит маршруты каждого сервиса.

## Реализации (контроллеры)

Gateway API — только спецификация, нужен контроллер:

| Реализация | Основа | Комментарий |
|---|---|---|
| **Envoy Gateway** | Envoy | проект CNCF, частый выбор «по умолчанию» |
| **NGINX Gateway Fabric** | NGINX | для тех, кто хочет остаться на NGINX |
| **Cilium** | eBPF + Envoy | если Cilium уже стоит как CNI |
| **Istio** | Envoy | вместе с service mesh |
| **Traefik**, **Kong**, **HAProxy** | свои | поддерживают и Ingress, и Gateway API |
| **GKE / AWS / Azure** | облачные LB | Gateway создаёт управляемый балансировщик облака |

Список и уровень совместимости — на [gateway-api.sigs.k8s.io/implementations](https://gateway-api.sigs.k8s.io/implementations/).

## Установка (на примере Envoy Gateway)

```bash
# 1. CRD Gateway API (часто ставятся вместе с контроллером — смотри его документацию)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<версия>/standard-install.yaml

# 2. контроллер
helm install eg oci://docker.io/envoyproxy/gateway-helm -n envoy-gateway-system --create-namespace

# 3. проверить
kubectl get gatewayclass
kubectl api-resources | grep gateway.networking.k8s.io
```

> Версии CRD и контроллера должны быть совместимы — бери версию из документации выбранной реализации.

## Минимальный пример

### GatewayClass (обычно уже создан контроллером)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

### Gateway — точка входа

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public
  namespace: infra
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All              # маршруты из любых namespace (или Same / Selector)
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-example-com     # Secret с сертификатом
      allowedRoutes:
        namespaces:
          from: All
```

```bash
kubectl get gateway -n infra
# NAME     CLASS   ADDRESS        PROGRAMMED   AGE
# public   eg      203.0.113.10   True         1m
```

Контроллер создаст Service `LoadBalancer` — `ADDRESS` и есть внешний IP, на который указывает DNS.

### HTTPRoute — маршруты приложения

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: shop
spec:
  parentRefs:
    - name: public
      namespace: infra
      sectionName: https           # к какому listener подключиться
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: shop-api
          port: 8080
    - backendRefs:                 # всё остальное — фронтенд
        - name: shop-web
          port: 80
```

Тот же маршрут на классическом Ingress для сравнения:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: shop
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend: { service: { name: shop-api, port: { number: 8080 } } }
          - path: /
            pathType: Prefix
            backend: { service: { name: shop-web, port: { number: 80 } } }
```

## Возможности без аннотаций

### Редирект HTTP → HTTPS

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: infra
spec:
  parentRefs:
    - name: public
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

### Canary: 90% / 10%

```yaml
rules:
  - backendRefs:
      - name: shop-api-v1
        port: 8080
        weight: 90
      - name: shop-api-v2
        port: 8080
        weight: 10
```

Меняешь веса 90/10 → 50/50 → 0/100 — это и есть canary-деплой (см. [CD: стратегии](cd-strategies.md)). Argo Rollouts и Flagger умеют менять веса автоматически.

### Маршрут по заголовку (тестировщики видят новую версию)

```yaml
rules:
  - matches:
      - headers:
          - name: X-Canary
            value: "true"
    backendRefs:
      - name: shop-api-v2
        port: 8080
  - backendRefs:
      - name: shop-api-v1
        port: 8080
```

### Rewrite пути и заголовки

```yaml
rules:
  - matches:
      - path: { type: PathPrefix, value: /legacy }
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /v2
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
            - name: X-Env
              value: prod
    backendRefs:
      - name: shop-api
        port: 8080
```

### Таймауты

```yaml
rules:
  - timeouts:
      request: 30s
    backendRefs:
      - name: shop-api
        port: 8080
```

### Сервис в другом namespace — ReferenceGrant

По умолчанию HTTPRoute может ссылаться только на Service **в своём** namespace. Чтобы разрешить ссылку из `shop` на Service в `payments`, владелец `payments` создаёт:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-shop
  namespace: payments
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: shop
  to:
    - group: ""
      kind: Service
```

## TLS с cert-manager

cert-manager умеет выпускать сертификаты для Gateway: включается поддержка Gateway API в cert-manager, затем аннотация на Gateway:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

cert-manager увидит `certificateRefs` в listener-ах и создаст/продлит Secret с сертификатом. Детали включения зависят от версии cert-manager — смотри его документацию.

## Миграция с Ingress

1. **Инвентаризация**: `kubectl get ingress -A`, выписать все используемые аннотации — это и есть объём работ.
2. **Выбрать реализацию** Gateway API и поставить её **рядом** с текущим ingress-controller.
3. **Сконвертировать манифесты** утилитой **ingress2gateway** (проект kubernetes-sigs):

    ```bash
    ingress2gateway print --providers=ingress-nginx --all-namespaces > gateway-resources.yaml
    ```

    Утилита переводит стандартные поля и часть аннотаций; остальное (rate limit, auth, custom snippets) — вручную, через фильтры или policy-ресурсы выбранной реализации.
4. **Проверить** новый Gateway по его IP, не трогая DNS: `curl -H "Host: shop.example.com" http://<gateway-ip>/api`.
5. **Переключить DNS** (или веса на внешнем балансировщике) постепенно, сервис за сервисом.
6. **Удалить** Ingress-объекты и старый контроллер, когда трафик ушёл.

## Диагностика

```bash
kubectl get gatewayclass                         # ACCEPTED=True?
kubectl get gateway -A                           # PROGRAMMED=True, есть ADDRESS?
kubectl get httproute -A
kubectl describe httproute shop -n shop          # Conditions: Accepted, ResolvedRefs
kubectl get gateway public -n infra -o yaml | yq '.status'
```

Главное — **смотреть `status.conditions`**, там написано, почему маршрут не работает:

| Condition | Если `False` |
|---|---|
| `Accepted` (Route) | Gateway не принял маршрут: не тот `parentRefs`/`sectionName`, `allowedRoutes` не пускает namespace, hostname не совпадает с listener |
| `ResolvedRefs` (Route) | нет такого Service/порта или нужен `ReferenceGrant` |
| `Programmed` (Gateway) | контроллер не смог настроить прокси/LoadBalancer — логи контроллера |

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `no matches for kind "HTTPRoute"` | не установлены CRD Gateway API | поставить `standard-install.yaml` нужной версии |
| Gateway без ADDRESS | нет LoadBalancer-провайдера (локальный кластер) | MetalLB (см. [K8s LoadBalancer](k8s-loadbalancer.md)) или `kubectl port-forward` к Service контроллера |
| HTTPRoute `Accepted: False` | namespace не разрешён в `allowedRoutes` | `from: All` / `Selector` в listener |
| `ResolvedRefs: False, RefNotPermitted` | Service в другом namespace | `ReferenceGrant` в namespace сервиса |
| 404 на все запросы | hostname маршрута не совпадает с hostname listener-а | привести в соответствие `hostnames` и `listeners[].hostname` |
| После миграции пропали rate limit / auth | это были аннотации ingress-nginx | реализовать через policy-ресурсы выбранного контроллера |

## Best Practices

* **Новые кластеры — сразу на Gateway API**, не на Ingress.
* **Gateway в отдельном namespace** (`infra`, `gateway`) под управлением платформенной команды, HTTPRoute — в namespace приложений.
* **Ограничивай `allowedRoutes`** через `Selector` по меткам namespace, а не `All` в проде.
* **Держись стандартных полей**: чем меньше специфичных для реализации policy, тем проще сменить контроллер.
* **Мигрируй постепенно**: два контроллера параллельно, переключение по одному сервису.
* **Манифесты — в git и через GitOps** (см. [GitOps](gitops.md)).
