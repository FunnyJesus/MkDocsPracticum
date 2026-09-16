# Безопасность (DevSecOps)

DevSecOps — встраивание проверок безопасности в тот же конвейер, где живут сборка и деплой, а не отдельный аудит раз в год. Ниже — темы, которые чаще всего спрашивают на DevOps-собеседованиях и которые не завязаны на конкретный инструмент из других разделов.

## Принцип наименьших привилегий (least privilege)

Давать ровно те права, которые нужны для задачи, не больше. Проявляется на каждом уровне стека:

| Уровень | Пример least privilege | Где в конспекте |
|---|---|---|
| Контейнер | Не запускать процесс от root (`USER appuser`) | [Docker](docker.md) |
| Kubernetes | RBAC-роль сервис-аккаунта пода ограничена namespace | ниже |
| Облако | IAM-роль CI ограничена нужным ресурсом, не `admin` | [Облака](cloud.md) |
| SSH | Ключи вместо пароля, отдельный непривилегированный пользователь | ниже |
| CI/CD | Секрет доступен только нужному job/окружению | ниже |

> Это одна и та же идея на разных уровнях — стоит запомнить её один раз и применять везде, а не как отдельное правило под каждый инструмент.

## Управление секретами

**Секрет** — пароль, токен, приватный ключ, API-key. Главное правило: **секреты не хранятся в git** (даже в приватном репозитории — история остаётся навсегда, даже после удаления файла).

| Подход | Где применяется | Комментарий |
|---|---|---|
| `.gitignore` + `.env` локально | Разработка | Минимум — не закоммитить случайно |
| CI/CD secrets (защищённые переменные) | GitLab CI/GitHub Actions | См. [CI](ci.md) — секреты не попадают в логи и форк-PR |
| Docker/Compose `secrets` | Контейнеры | Монтируются файлом, не через env (см. [Docker Compose](docker-compose.md)) |
| Kubernetes `Secret` | Кластер | По умолчанию хранится в base64 (не шифрование!), нужен encryption at rest |
| **Vault** (HashiCorp) | Централизованное хранилище секретов | Динамические секреты (выдаются на время), аудит доступа, ротация |
| Облачный KMS/Secret Manager | AWS Secrets Manager, Yandex Lockbox | Managed-аналог Vault, интеграция с IAM облака |

> **Kubernetes Secret — это не шифрование**, а просто base64 (тривиально декодируется: `echo <value> | base64 -d`). Для реальной защиты нужны encryption at rest на уровне etcd или внешний секрет-менеджер (Vault, облачный KMS).

```bash
# типичный сценарий утечки — секрет в истории git
git log -p -- config.py | grep -i "password\|token\|key"

# если секрет всё же закоммичен — недостаточно удалить файл и закоммитить снова,
# он остаётся в истории. Нужно: сменить сам секрет (отозвать) + очистить историю
# (git filter-repo / BFG Repo-Cleaner), если репозиторий публичный.
```

## Сканирование на уязвимости

| Тип | Что проверяет | Инструменты |
|---|---|---|
| **SCA** (Software Composition Analysis) | Известные уязвимости в зависимостях (CVE) | `npm audit`, `pip-audit`, Trivy, Dependabot |
| **Сканирование образов** | Уязвимости в слоях Docker-образа (базовый образ, пакеты ОС) | Trivy, Docker Scout, Grype |
| **SAST** (Static Application Security Testing) | Уязвимости в исходном коде без запуска | SonarQube, Semgrep |
| **DAST** (Dynamic Application Security Testing) | Уязвимости у запущенного приложения (как реальная атака) | OWASP ZAP, Burp Suite |
| **IaC-сканирование** | Небезопасная конфигурация в Terraform/K8s-манифестах | tfsec, checkov, kube-score |

```bash
# просканировать образ на известные уязвимости
trivy image python:3.12-slim

# просканировать Terraform-код на небезопасные настройки
tfsec .
checkov -d .
```

> Тестировщику эта область особенно близка: DAST по сути — те же функциональные/негативные тесты, только с фокусом на security-сценарии (SQL-инъекции, XSS, обход авторизации). **OWASP Top 10** — стандартный список самых частых уязвимостей веб-приложений (Injection, Broken Authentication, Broken Access Control, Security Misconfiguration и т.д.) — полезный ориентир и для ручного/автотестирования, и для DevSecOps.

## SSH-хардening

```
# /etc/ssh/sshd_config
PasswordAuthentication no      # только ключи, не пароли
PermitRootLogin no             # root не логинится напрямую по SSH
Port 2222                      # смена порта снижает шум от автоматических сканеров (не замена остальных мер)
AllowUsers deploy               # разрешить конкретных пользователей
```

* **Ключи вместо паролей** — пароль можно подобрать/перебрать, приватный ключ — нет (при достаточной длине).
* **fail2ban** — банит IP после N неудачных попыток входа (защита от перебора).
* **Bastion host / jump host** — единственная машина с доступом по SSH из интернета, остальные серверы доступны только через неё (приватная подсеть, см. [Облака](cloud.md)).

```bash
ssh-keygen -t ed25519 -C "you@example.com"     # сгенерировать ключевую пару
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host  # скопировать публичный ключ на сервер
```

## Безопасность в Kubernetes

* **RBAC** (Role-Based Access Control) — кто (пользователь/ServiceAccount) что может делать (verbs: get/list/create/delete) с какими ресурсами (Pod, Deployment, Secret) в каком namespace.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]   # только чтение подов — не удаление, не секреты
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
  - kind: ServiceAccount
    name: ci-deployer
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

* **NetworkPolicy** — firewall на уровне подов: какие поды могут обращаться друг к другу (по умолчанию в Kubernetes весь трафик между подами разрешён).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: only-from-frontend
spec:
  podSelector:
    matchLabels:
      app: order-service
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend      # только frontend может обращаться к order-service
```

* **Pod Security** — запрет запуска от root, `readOnlyRootFilesystem`, запрет privileged-контейнеров:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

## Supply chain security

* **Пиннинг версий** — уже упоминалось в [Docker](docker.md): `FROM python:3.12-slim`, а не `FROM python:latest`. Незафиксированная версия — точка, через которую может прилететь скомпрометированный апдейт.
* **SBOM** (Software Bill of Materials) — «список ингредиентов» образа/приложения: какие пакеты и версии внутри. Нужен, чтобы быстро понять, затронула ли тебя новая CVE, не пересобирая и не сканируя всё заново.
* **Подписанные образы** (image signing, например cosign) — подтверждение, что образ действительно собран вашим CI, а не подменён по пути в реестре.

## CI/CD и секреты

* Секреты CI (токены облака, ключи деплоя) хранятся как защищённые переменные окружения платформы, не в коде пайплайна.
* Секреты не должны попадать в вывод job'а (многие платформы автоматически маскируют известные секретные переменные в логах — но не гарантированно, если секрет напечатан не напрямую, а, например, в base64).
* Отдельный сервисный аккаунт/токен на пайплайн, а не переиспользование личного токена разработчика — иначе увольнение сотрудника = нужно менять секреты всех пайплайнов.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Секрет утёк через git-историю | Закоммитили `.env`/ключ и просто удалили файл | Отозвать/сменить секрет, очистить историю (BFG/filter-repo) |
| «Расшифровали» Kubernetes Secret | Приняли base64 за шифрование | encryption at rest + внешний секрет-менеджер для чувствительных данных |
| Скомпрометированный образ из публичного registry | Образ с `latest` без сканирования и пиннинга | Пиннинг версии + сканирование (Trivy) в CI перед деплоем |
| Любой под может достучаться до базы | Нет NetworkPolicy — по умолчанию всё разрешено | Явные NetworkPolicy с deny-by-default |
| SSH ломают перебором | Пароль вместо ключа, root доступен напрямую | Ключи, `PermitRootLogin no`, fail2ban |

## Best Practices

* **Least privilege на каждом уровне** — от SSH-пользователя до IAM-роли CI.
* **Секреты — только через специализированный механизм** (CI secrets, Vault, K8s Secret + encryption, Docker secrets), никогда в коде/env напрямую в репозитории.
* **Сканируй образы и зависимости в CI**, а не постфактум вручную.
* **Deny by default** в сетевых политиках (K8s NetworkPolicy, security groups) — разрешать явно, а не запрещать явно.
* **Пинни версии** — базовые образы, провайдеры Terraform, зависимости — воспроизводимость это ещё и безопасность.
