# Секреты: Vault, External Secrets, Sealed Secrets, SOPS

> Общие принципы и почему Kubernetes Secret — не шифрование — [Безопасность](security.md). Секреты в GitOps — [GitOps](gitops.md).

Задача: у приложения должен быть пароль от базы, но этого пароля **не должно быть** в git, в Docker-образе, в логах CI и в голове у каждого разработчика. При этом GitOps хочет, чтобы **всё** лежало в git. Ниже — как совмещают.

## Варианты

| Подход | Где хранится секрет | В git лежит | Когда |
|---|---|---|---|
| **HashiCorp Vault** | в Vault | ничего (ссылка) | центральное хранилище, динамические секреты, аудит |
| **External Secrets Operator (ESO)** | во внешнем хранилище (Vault, AWS SM, Yandex Lockbox…) | манифест «какой секрет взять» | Kubernetes + внешнее хранилище |
| **Sealed Secrets** | в git, зашифрованный | зашифрованный `SealedSecret` | простой GitOps без внешнего хранилища |
| **SOPS** | в git, зашифрованы значения | файл с зашифрованными значениями | GitOps, Helm values, Terraform, Ansible |
| Облачный Secret Manager | AWS Secrets Manager, GCP Secret Manager, Yandex Lockbox | ничего | в облаке, интеграция с IAM |

## HashiCorp Vault

**Vault** — сервер для хранения и выдачи секретов с аутентификацией, политиками доступа и аудитом.

### Основные понятия

| Понятие | Что это |
|---|---|
| **Secrets engine** | «движок» хранения: `kv` (ключ-значение), `database` (динамические пароли), `pki` (сертификаты), `aws` (временные ключи) |
| **Auth method** | как клиент доказывает, кто он: token, userpass, **kubernetes**, **approle** (CI), OIDC |
| **Policy** | что разрешено: пути и операции |
| **Lease / TTL** | время жизни выданного секрета |
| **Seal / Unseal** | после запуска Vault «запечатан», данные нельзя прочитать, пока его не распечатают ключами (или auto-unseal через облачный KMS) |

### Локально для практики

```bash
vault server -dev                              # dev-режим: в памяти, уже распечатан, НЕ для прода
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root token из вывода>
```

### KV — статические секреты

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/shop/db username=app password='s3cr3t'
vault kv get secret/shop/db
vault kv get -field=password secret/shop/db
vault kv metadata get secret/shop/db           # версии (kv-v2 хранит историю)
vault kv rollback -version=1 secret/shop/db
```

### Политика

```hcl
# shop-read.hcl — читать только секреты shop
path "secret/data/shop/*" {
  capabilities = ["read"]
}
```

```bash
vault policy write shop-read shop-read.hcl
```

### Аутентификация из Kubernetes

Под доказывает, кто он, своим ServiceAccount-токеном:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
vault write auth/kubernetes/role/shop \
  bound_service_account_names=shop \
  bound_service_account_namespaces=shop \
  policies=shop-read \
  ttl=1h
```

Дальше секрет доставляют в под одним из способов: **Vault Agent Injector** (sidecar пишет секрет в файл), **Vault Secrets Operator**, **CSI driver** или **External Secrets Operator** (ниже).

### Динамические секреты

Vault сам создаёт пользователя в PostgreSQL на время и удаляет по истечении TTL:

```bash
vault secrets enable database
vault write database/config/appdb \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@db:5432/appdb" \
  allowed_roles=shop username=vault password=...
vault write database/roles/shop \
  db_name=appdb default_ttl=1h max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

vault read database/creds/shop       # каждый раз — новый логин и пароль
```

Утёк пароль — он всё равно умрёт через час. Нет «вечного» пароля от прод-базы, который знают все.

## External Secrets Operator (ESO)

Оператор в Kubernetes, который **читает секрет из внешнего хранилища и создаёт обычный Kubernetes Secret**. В git лежит только описание «откуда что взять».

```yaml
# подключение к хранилищу (один раз на namespace или кластер)
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault
  namespace: shop
spec:
  provider:
    vault:
      server: https://vault.example.com
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: shop
```

```yaml
# какой секрет нужен приложению
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: shop-db
  namespace: shop
spec:
  refreshInterval: 1h            # перечитывать — подхватит ротацию
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: shop-db                # имя создаваемого Kubernetes Secret
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: shop/db
        property: password
```

```bash
kubectl get externalsecret -n shop     # STATUS: SecretSynced
kubectl get secret shop-db -n shop
```

> Версия API (`v1` / `v1beta1`) зависит от версии ESO — смотри документацию установленной версии.

## Sealed Secrets

Контроллер в кластере держит **приватный ключ**. Утилита `kubeseal` шифрует секрет **публичным** ключом — расшифровать может только этот кластер. Зашифрованный `SealedSecret` можно спокойно коммитить.

```bash
# установка контроллера — Helm-чарт sealed-secrets, затем:
kubectl create secret generic shop-db \
  --from-literal=DB_PASSWORD='s3cr3t' \
  --dry-run=client -o yaml \
| kubeseal --format yaml > shop-db-sealed.yaml

git add shop-db-sealed.yaml       # безопасно
kubectl apply -f shop-db-sealed.yaml    # контроллер создаст обычный Secret
```

* Плюс: просто, без внешних сервисов.
* Минус: **сохрани приватный ключ контроллера** (бэкап) — пересоздал кластер без него = все SealedSecret-ы не расшифровать. Ротация секрета — перешифровать и закоммитить.

## SOPS

**SOPS** (Mozilla, теперь CNCF) шифрует **значения** в YAML/JSON/ENV-файлах, оставляя ключи читаемыми — удобно на ревью. Ключи шифрования: **age**, PGP, AWS/GCP KMS, Vault.

```bash
age-keygen -o ~/.config/sops/age/keys.txt     # создать ключ
# публичный ключ: age1ql3z7hjy...
```

```yaml
# .sops.yaml в корне репо — какие файлы каким ключом шифровать
creation_rules:
  - path_regex: .*/secrets.*\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

```bash
sops -e -i secrets.prod.yaml     # зашифровать на месте
sops secrets.prod.yaml           # открыть в редакторе расшифрованным, при сохранении — зашифрует
sops -d secrets.prod.yaml        # расшифровать в stdout
```

Результат в git:

```yaml
db:
  password: ENC[AES256_GCM,data:Tr7o1...,iv:...,tag:...,type:str]
sops:
  age:
    - recipient: age1ql3z7hjy...
```

Интеграции: **helm-secrets** (`helm secrets upgrade ... -f secrets.yaml`), **Flux** (встроенная расшифровка), Argo CD (через плагин), **Terraform** (провайдер `sops`), Ansible (`community.sops`).

## Секреты в CI/CD

* Хранить в защищённых переменных CI (masked + protected), не в `.gitlab-ci.yml`.
* Лучше — **без долгоживущих ключей вообще**: CI получает временный доступ через **OIDC** (GitHub Actions / GitLab → AWS/GCP/Vault по JWT-токену джоба).
* Не печатать секреты в логи (`set -x` в bash печатает всё!).

## Ротация

Секрет, который не меняли 3 года, знают все, кто работал в команде за 3 года.

* Регулярная смена паролей и ключей (лучше автоматическая).
* При уходе сотрудника или утечке — немедленная смена.
* Приложение должно уметь подхватить новый секрет: перечитать файл, перезапуск по изменению (Reloader, хеш в аннотации пода), динамические секреты.

## Частые ошибки

| Симптом | Причина | Решение |
|---|---|---|
| Секрет в git в открытом виде | «временно» закоммитили `.env` / values | отозвать секрет, очистить историю; pre-commit хук **gitleaks** |
| Пересоздали кластер — SealedSecret не расшифровывается | потерян приватный ключ контроллера | бэкап ключа sealed-secrets в надёжном месте |
| Поменяли секрет в Vault — приложение со старым | Secret обновился, а под — нет | `refreshInterval` в ESO + Reloader / перезапуск |
| `ExternalSecret` в статусе `SecretSyncedError` | неверный путь/ключ или нет прав в политике Vault | `kubectl describe externalsecret`, проверить policy и role |
| Vault недоступен после рестарта | Vault запечатан | unseal ключами или auto-unseal через KMS |
| Пароль в логах CI | `echo`/`set -x`, секрет не masked | masked-переменные, не печатать |

## Best Practices

* **В git — только зашифрованное или ссылки** (SOPS, SealedSecret, ExternalSecret).
* **Одно центральное хранилище** (Vault / облачный Secret Manager) + ESO в кластерах.
* **Короткоживущие и динамические секреты** вместо вечных.
* **OIDC для CI** вместо статических ключей облака.
* **gitleaks / trufflehog** в pre-commit и CI.
* **Бэкап ключей шифрования** (age, sealed-secrets, unseal keys) — отдельно и надёжно.
