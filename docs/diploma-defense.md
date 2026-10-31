# Диплом: вопросы для защиты

Самопроверка по своему же проекту: что может спросить ревьюер или интервьюер.
Сначала ответь сам, потом открой ответ. Общий обзор — [на главной странице раздела](diploma-momo-store.md).

## Архитектура и решения

**1. Почему GitHub Flow, а не Git Flow?**

??? success "Ответ"
    Один продукт и одно production-окружение. Git Flow (`develop`, `release/*`, `hotfix/*`) нужен, когда
    поддерживается несколько версий одновременно или есть долгий цикл релиза. Здесь он только удлиняет
    путь до прода. В GitHub Flow `master` всегда готов к релизу, изменения — через MR с зелёным пайплайном,
    релиз — тег.

**2. Откуда берётся версия и почему не `1.0.${CI_PIPELINE_ID}`?**

??? success "Ответ"
    Из аннотированного git-тега `vX.Y.Z`. Номер пайплайна не несёт смысла (MAJOR/MINOR/PATCH), растёт от
    любого запуска и не связан с кодом. Тег однозначно указывает на коммит, и все артефакты релиза
    (два образа и чарт) получают одну версию.

**3. Что такое «build once» и как он реализован?**

??? success "Ответ"
    Образ собирается один раз, тестируется, и в прод идёт **тот же digest**. На теге kaniko собирает
    `:<sha>`, test его сканирует, на release `crane tag :<sha> X.Y.Z` добавляет тег без пересборки
    и без перекачки слоёв. Пересборка на релизе могла бы дать другой образ (обновились пакеты, базовый образ).

**4. Почему прерываемые узлы и что будет, когда узел прервут?**

??? success "Ответ"
    В разы дешевле — рекомендация задания для экономии гранта. ВМ живёт ≤ 24 ч и может быть остановлена
    в любой момент с предупреждением ~30 с через метаданные (`instance/preempted = TRUE`). DaemonSet
    `preemptible-handler` видит это и делает `cordon` + `drain`: поды корректно завершаются (SIGTERM,
    `preStop`), Service убирает их из endpoints, планировщик ставит новые на другой узел. Выживаемость
    дают 2 реплики, `podAntiAffinity` по узлам и PDB `minAvailable: 1`. После перезапуска ВМ обработчик
    снимает cordon (по своей аннотации).

**5. Почему зональный мастер? Чем рискуешь?**

??? success "Ответ"
    Дешевле регионального в несколько раз. Риск — при недоступности зоны или обслуживании мастера
    недоступен Kubernetes API: нельзя деплоить и масштабировать. Уже запущенные поды продолжают работать.
    Для учебного проекта приемлемо, для прода — региональный мастер и узлы в 3 зонах.

**6. Зачем nginx фронтенда проксирует API, а не Ingress напрямую в backend?**

??? success "Ответ"
    Исходный backend отдаёт ссылки на картинки в Cloudinary, а код менять нельзя. nginx переписывает их
    в ответах на бакет Object Storage (`sub_filter`). Заодно: наружу публикуется только белый список
    ресурсов API (`/metrics`, `/health` закрыты), а backend по NetworkPolicy доступен только из frontend —
    даже ingress-nginx до него не достаёт.

**7. Почему приложение открывается по `/momo-store/`?**

??? success "Ответ"
    В исходном `vue.config.js` для production `publicPath: '/momo-store/'` — бандл ссылается на
    `/momo-store/js/...`, и vue-router использует этот base. Менять нельзя, поэтому `dist` лежит в
    `/usr/share/nginx/html/momo-store`, а `/` отдаёт 302 на `/momo-store/`.

## Terraform

**8. Где хранится state и как решена проблема «курицы и яйца»?**

??? success "Ответ"
    В приватном бакете Object Storage с версионированием: `bootstrap/terraform.tfstate` и
    `prod/terraform.tfstate`. Бакет создаёт сам Terraform, поэтому bootstrap сначала запускается
    с локальным state, а после apply переносится в бакет командой `terraform init -migrate-state`.
    Локальная копия удаляется — в ней ключи.

**9. Есть ли блокировка state? Чем опасно её отсутствие?**

??? success "Ответ"
    Нет. Два одновременных `apply` могут записать state поверх друг друга и испортить его.
    Риск принят: Terraform запускаю только я, CI делает лишь `validate` без доступа к state.
    Для команды — блокировка через serverless YDB (DynamoDB-совместимый API) или
    `use_lockfile` при поддержке хранилищем. Версионирование бакета позволяет откатить испорченный state.

**10. Почему у SA terraform роль admin? Это не слишком много?**

??? success "Ответ"
    Конфигурация создаёт сервисные аккаунты и назначает им роли — для этого нужно управлять
    access bindings, а `editor` этого не позволяет. Роль выдана только на один каталог. Остальные SA —
    с минимальными ролями: узлы только pull из реестра, CI только push, роли — на уровне реестра,
    а не каталога.

**11. `iam_binding` vs `iam_member` — в чём разница?**

??? success "Ответ"
    `*_iam_binding` **авторитативен**: задаёт полный список участников роли и удалит всех остальных,
    у кого эта роль была. `*_iam_member` добавляет одного участника и не трогает других. На уровне
    каталога безопасен `iam_member`; `iam_binding` — только на ресурсах, которыми Terraform управляет
    целиком (у меня — на реестре и KMS-ключе).

**12. Почему Calico включён сразу, хотя zero-trust — задача со звёздочкой?**

??? success "Ответ"
    `network_policy_provider` в Managed Kubernetes задаётся только при создании кластера. Без него
    объекты NetworkPolicy создаются, но **игнорируются**. Включить потом — только пересоздать кластер.

**13. Как проверить, что инфраструктура соответствует коду?**

??? success "Ответ"
    `terraform plan` → `No changes. Your infrastructure matches the configuration.`
    (`-detailed-exitcode`: 0 — нет изменений, 2 — есть). Ручные изменения в консоли покажутся как дрейф.

**14. Зачем `skip_region_validation` и прочие `skip_*` в backend?**

??? success "Ответ"
    S3-backend написан под AWS: без них он проверяет регион по списку AWS, ходит в STS за учётной
    записью и считает checksum так, как Object Storage не поддерживает.

## Kubernetes и Helm

**15. Чем отличаются readiness и liveness? Что будет, если перепутать?**

??? success "Ответ"
    Readiness — «готов принимать трафик»: при провале под убирается из endpoints Service, но не
    перезапускается. Liveness — «жив ли процесс»: при провале kubelet перезапускает контейнер.
    Если сделать liveness слишком строгой (например, зависящей от БД), временная проблема зависимости
    вызовет каскад рестартов. Readiness — это ещё и основа `helm --atomic` и rolling update.

**16. Почему в Deployment нет `replicas`, когда включён HPA?**

??? success "Ответ"
    Иначе каждый `helm upgrade` выставлял бы `replicas` из values и сбрасывал число реплик,
    выбранное HPA. Шаблон пишет `replicas` только при `autoscaling.enabled: false`.

**17. Как работает HPA по CPU и почему без requests он не работает?**

??? success "Ответ"
    HPA берёт метрики из metrics-server и считает утилизацию как `usage / requests`. Желаемое число реплик
    — `ceil(текущие × текущая утилизация / целевая)`, в пределах min/max. Без `requests` знаменателя нет —
    HPA пишет `<unknown>`. Scale-down с окном стабилизации 5 минут, чтобы не «дёргаться» на кратких спадах.
    Узлы не масштабируются (2 узла под квоты); при `node_max_count = 3` поды в Pending вызвали бы Cluster Autoscaler.

**18. Что делает `maxUnavailable: 0, maxSurge: 1`?**

??? success "Ответ"
    При обновлении сначала поднимается один новый под, и только после его Ready убирается старый.
    Число работающих реплик не опускается ниже желаемого — обновление без даунтайма.

**19. Зачем PDB, если есть 2 реплики?**

??? success "Ответ"
    `kubectl drain` (обработчик прерываний, обновление узлов) вытесняет поды через Eviction API, который
    учитывает PDB. С `minAvailable: 1` drain не уберёт обе реплики разом, даже если они случайно на одном узле.

**20. Что защищает securityContext в чарте?**

??? success "Ответ"
    `runAsNonRoot` + конкретный uid — процесс не root; `readOnlyRootFilesystem` — нельзя записать
    в файловую систему контейнера (для nginx — `emptyDir` в `/tmp`); `allowPrivilegeEscalation: false`
    и `capabilities.drop: [ALL]` — нельзя поднять привилегии; `seccompProfile: RuntimeDefault` — фильтр
    системных вызовов; `automountServiceAccountToken: false` — у приложения нет токена к API кластера.

**21. Как устроен zero-trust? Как проверить?**

??? success "Ответ"
    `default-deny-all` (ingress и egress) для всех подов namespace, затем явные разрешения: DNS
    в kube-dns, ingress-nginx → frontend:8080, frontend → backend:8081, monitoring → backend:8081 и
    exporter:9113. Проверка — под из другого namespace:
    `kubectl run probe -n default --rm -it --image=curlimages/curl -- curl -m 3 http://momo-store-backend.momo-store:8081/health`
    → timeout.

**22. Почему у CI свой ServiceAccount, а не админский kubeconfig?**

??? success "Ответ"
    Минимальные права: `admin` только в namespace `momo-store` (плюс CRD мониторинга). Если ключ
    утечёт из CI — нельзя тронуть платформу, `kube-system`, другие namespace. `kubectl auth can-i`
    это подтверждает. Плюс переменная Protected — доступна только пайплайнам защищённых тегов.

## CI/CD

**23. Как работает автооткат?**

??? success "Ответ"
    `helm upgrade --atomic --wait --timeout 5m`: Helm ждёт, пока ресурсы станут готовы (поды Ready);
    если нет — откатывает на предыдущую ревизию и завершается с ошибкой. Второй уровень — smoke-тест через
    Ingress снаружи, при провале — `helm rollback`. Проверка: выпустить версию со сломанной
    readinessProbe — откат, красный пайплайн, уведомление.

**24. Почему kaniko, а не docker-in-docker?**

??? success "Ответ"
    DinD требует privileged-раннер (фактически root на хосте раннера). Kaniko собирает образ
    в userspace без демона Docker и без привилегий — работает на общих раннерах.
    (Upstream kaniko архивирован, на будущее — buildah/BuildKit rootless.)

**25. Как CI авторизуется в Container Registry?**

??? success "Ответ"
    Логин `json_key`, пароль — JSON авторизованного ключа SA CI (File-переменная `YC_CI_KEY`).
    Для kaniko и trivy — `config.json` с `auth = base64("json_key:<json>")`, для crane и helm —
    их `login`. IAM-токены не нужны.

**26. Что такое Protected и Masked у переменных? Почему у `YC_CI_KEY` нет Protected?**

??? success "Ответ"
    Protected — переменная доступна только защищённым веткам/тегам. Masked — значение скрывается
    в логах (есть требования к формату). `YC_CI_KEY` нужен build на любой ветке для push образов,
    поэтому без Protected. `KUBECONFIG` — Protected: деплой только с защищённого тега `v*`.

**27. Что проверяет стадия test?**

??? success "Ответ"
    golangci-lint, `go vet` и `go test -race` с покрытием; trivy по собранным образам
    (блок на CRITICAL с исправлением); hadolint по Dockerfile; `helm lint` + рендер + kubeconform;
    `terraform fmt -check` + `validate`; `npm audit` (не блокирующий); SonarQube — если настроен.

**28. Как собираются Release Notes?**

??? success "Ответ"
    Из git с предыдущего тега: merge-коммиты GitLab содержат заголовок MR и строку
    `See merge request group/project!N` → номер и ссылка на MR; авторы — `git log A^1..A^2` (коммиты из
    ветки MR); отдельно список коммитов и авторов, ссылки на артефакты. Релиз создаётся через
    Releases API с `CI_JOB_TOKEN`. Нужна полная история — `GIT_DEPTH: "0"`.

## Мониторинг

**29. Что такое R.E.D. и откуда каждая буква на дашборде?**

??? success "Ответ"
    Rate / Errors / Duration. Rate — `requests_count` и `response_timing_ms_count` backend, для frontend —
    `nginx_ingress_controller_requests`. Errors — только из ingress-nginx (в метриках backend нет кода
    ответа), отдельно для Ingress `*-api` и `*-frontend`. Duration — `histogram_quantile` по
    `response_timing_ms_bucket` (мс) и `nginx_ingress_controller_request_duration_seconds_bucket`.
    Плюс Saturation — CPU/память подов, реплики, рестарты.

**30. Как Prometheus находит приложение?**

??? success "Ответ"
    Через ServiceMonitor (CRD prometheus-operator): селектор по меткам Service и имя порта. В values
    kube-prometheus-stack `serviceMonitorSelectorNilUsesHelmValues: false` — иначе Prometheus берёт
    только ServiceMonitor с меткой своего релиза. Проверка — `up{namespace="momo-store"}`.

**31. Как дашборд попадает в Grafana?**

??? success "Ответ"
    JSON лежит в чарте приложения, рендерится в ConfigMap с меткой `grafana_dashboard: "1"`. Sidecar
    Grafana следит за такими ConfigMap во всех namespace и загружает их. Дашборд версионируется вместе
    с приложением и переживает рестарт Grafana.

**32. Почему Grafana падала и как ты это нашёл?**

??? success "Ответ"
    В браузере `ChunkLoadError`. Файл по `curl` отдавался — значит, не постоянная ошибка. `kubectl get pods`
    показал рестарты, `lastState.terminated.reason` — `OOMKilled`, `kubectl top` — 250Mi при лимите 256Mi.
    Поднял лимит до 512Mi.

## Облако и экономика

**33. Сколько стоит стенд и как экономишь?**

??? success "Ответ"
    Основное — мастер (тарифицируется постоянно), 2 узла и NAT; сеть, IP, реестр, бакеты, KMS — копейки.
    Экономия: прерываемые ВМ, `core_fraction 50`, HDD, зональный мастер, нет Alertmanager, retention 3 дня,
    очистка реестра. Когда не нужен — `terraform destroy -target=module.kubernetes`, остальное остаётся,
    IP статический. Контроль — бюджет с уведомлениями и детализация в биллинге.

**34. Что бы ты сделал иначе для настоящего прода?**

??? success "Ответ"
    Региональный мастер и узлы в 3 зонах; обычные (не прерываемые) узлы для критичных подов или
    смешанные группы; домен + TLS (cert-manager); блокировка state; секреты в Lockbox/Vault через
    External Secrets; постоянный диск или внешняя БД для Grafana; Alertmanager с алертами по SLO;
    логи (Loki); отдельное staging-окружение; GitOps (Argo CD) вместо push-деплоя из CI;
    Gateway API вместо ingress-nginx (проект больше не развивается).
