# Мои конспекты DevOps

Это моя личная шпаргалка для учёбы и смены профессии на DevOps-инженера.

## Разделы

- [**Что такое DevOps**](devops.md) — зачем нужен DevOps, CALMS, жизненный цикл, метрики DORA, роли DevOps/SRE/Platform, карта навыков и порядок изучения
- [**Собеседование**](interview-mantra.md) — мантра на каждый день: 175+ вопросов с короткими ответами; [подробные ответы со ссылками](interview.md)
- [**Linux**](linux.md) — основы ОС: компоненты, процессы, базовые команды (`ls`, `cat`, `grep`, `find`, `ps`, `systemctl`, `tar`, сеть и др.); [структура каталогов и куда что деплоить](linux-filesystem.md); [диагностика и производительность](linux-troubleshooting.md), [обработка текста: grep, sed, awk, jq, yq](text-processing.md), [SSH: config, бастион, туннели](ssh.md), [tmux и vim](tmux-vim.md)
- [**Bash Script**](bash-scripts.md) — написание скриптов: переменные, массивы, операторы `|`, `||`, `&&`, циклы, функции, if-else, case
- [**Makefile**](makefile.md) — автоматизация команд проекта: цели, зависимости, `.PHONY`, переменные, `make help`, Makefile для Docker/Terraform/Helm
- [**Git**](git.md) — контроль версий: коммиты, ветки, слияния, работа с удалённым репозиторием
- [**CI**](ci.md) — непрерывная интеграция: Pipeline, Stage, Jobs, GitLab CI / GitHub Actions
- [**IaC (Terraform)**](iac.md) — инфраструктура как код: блоки (resource, provider, variable), команды terraform; [продвинутый Terraform](terraform-advanced.md) — remote state, модули, for_each, импорт, CI
- [**Docker**](docker.md) — контейнеризация: команды, Dockerfile, тома, сети, встроенный DNS; [Container Registry](registry.md) — теги, retention, доступ из K8s, подпись образов
- [**Kubernetes**](k8s.md) — оркестрация контейнеров: кластер, pods, deployments, services, ingress, k9s; [Gateway API](gateway-api.md) — замена Ingress и ingress-nginx; [Kustomize](kustomize.md) — base/overlays без шаблонов
- [**Helm**](helm.md) — пакетный менеджер K8s: чарты, шаблоны, values по окружениям, релизы и откаты; [production-ready чарт podinfo](helm-podinfo.md) — helpers, HPA, PDB, Redis, хуки и тесты
- [**GitOps / Argo CD**](gitops.md) — pull-деплой из git, Application, drift и selfHeal, app-of-apps, ApplicationSet
- [**Nginx**](nginx.md) — веб-сервер и reverse proxy: location, upstream, HTTPS и certbot, лимиты, разбор 502/504
- [**Сети**](networking.md) — OSI/TCP-IP, TCP vs UDP, DNS, HTTP/HTTPS, TLS, firewall, диагностика
- [**Базы данных**](databases.md) — PostgreSQL для DevOps: доступы, бэкапы и PITR, репликация, PgBouncer, диагностика, миграции; [очереди сообщений: Kafka и RabbitMQ](message-queues.md)
- [**Мониторинг и логи**](monitoring.md) — обзор стека, ELK/Loki, SLI/SLO/SLA, учебный стенд в Docker Compose; настройка: [Prometheus и Alertmanager](prometheus.md), [Grafana](grafana.md), [Vector](vector.md), [трейсинг и OpenTelemetry](tracing.md)
- [**SRE и надёжность**](sre.md) — error budget, burn rate, инциденты, on-call, runbook, blameless postmortem; [бэкапы и DR](backup-dr.md); [10 типовых инцидентов](incidents-practice.md)
- [**Облака**](cloud.md) — IaaS/PaaS/SaaS, IAM, VPC, object storage, managed vs self-hosted; [cloud-init](cloud-init.md) — первичная настройка VM и проверка его работы; [OpenStack](openstack.md) — Horizon UI и CLI: сети, VM, диски, floating IP, Octavia, Terraform
- [**Безопасность**](security.md) — секреты, сканирование уязвимостей, SSH-хардening, RBAC, NetworkPolicy; [секреты: Vault, External Secrets, Sealed Secrets, SOPS](secrets.md)
- [**Практика**](project-e2e.md) — сквозной проект для портфолио через весь стек

## Подход

- Пользуйтесь, но если хотите больше — создавайте и заполняйте свою
- Конспекты растут по мере изучения новых тем

Всем удачи ദ്ദി(｡•̀ᴗ-)✧
