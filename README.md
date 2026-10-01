# inference-ready-mks-cluster

Blueprint для LLM-инференса на Selectel Managed Kubernetes (MKS),
сосредоточенный на inference.

Один `terraform apply` с тумблерами поднимает: проект и service-пользователя, облачную сеть, кластер MKS, **Karpenter** (автоскейлер GPU-нод от Selectel), **AIBrix v0.7.0** (контроль-плейн LLM-инференса: маршрутизация, autoscaling по LLM-метрикам, динамическая загрузка LoRA, метадата моделей) и **LiteLLM Proxy** (auth-слой: virtual keys, бюджеты) — поверх vLLM.

```
                        ┌──────────────────────────────────────────────────┐
                        │              Selectel Cloud (ru-6)               │
                        │  проект + service-пользователь + сеть + роутер   │
                        │                                                  │
  клиенты ──(sk-…)──────┤  ┌────────────── MKS 1.34–1.36 ───────────────┐  │
  (https://имя.домен    │  │  edge-шлюз (envoy, LB, wildcard-TLS        │  │
  — единственный        │  │    *.домен, :80 → 301 на :443) —           │  │
  публичный вход)       │  │    единственный вход                       │  │
                        │  │    └─ LiteLLM Proxy — auth, virtual keys,  │  │
                        │  │       бюджеты/лимиты по ключам             │  │
                        │  │         └─ envoy/AIBrix (ClusterIP,        │  │
                        │  │            routing, rate limit, KV-aware)  │  │
                        │  │               └─ vLLM + LoRA               │  │
                        │  │                                            │  │
                        │  │   system-ноды (CPU, nodegroup=system):     │  │
                        │  │   edge-шлюз, LiteLLM (Deployment), envoy — │  │
                        │  │   дата-плейны, контроль-плейн AIBrix,      │  │
                        │  │   Postgres/Redis (ключи)                   │  │
                        │  │                                            │  │
                        │  │   GPU-ноды: создаёт Karpenter по NodePool  │  │
                        │  │  (L4 / RTX 4090 / RTX 6000 Pro / H200;     │  │
                        │  │  A100 — ru-7) ── vLLM                      │  │
                        │  └────────────────────────────────────────────┘  │
                        └──────────────────────────────────────────────────┘
```

**Почему LB AIBrix убран (сервис — ClusterIP):** (1) у AIBrix/envoy нет
аутентификации — любой LB (публичный или внутренний) был бы обходом auth-слоя;
(2) LiteLLM ходит в envoy по стабильному внутреннему имени
`aibrix-gateway.envoy-gateway-system.svc` (якорь-Service создаётся terraform'ом;
хэш-имя EG меняется между деплоями); (3) LB + его health-чеки — лишняя точка
отказа: пул деградировал (DEGRADED) при появлении CPU-нод без envoy.
Единственный публичный вход — edge-шлюз (HTTPS, wildcard `*.домен`, см.
«Домен и DNS»); оператор — через `kubectl port-forward`.

**Пиннинг на system-ноды:** у CPU-нодгруппы в terraform стоит лейбл
`nodegroup=system`. По нему пиннятся (nodeAffinity/nodeSelector) LiteLLM
(Deployment, 2 реплики), оба envoy-дата-плейна (edge-шлюз и AIBrix) и весь
контроль-плейн AIBrix. Новая CPU-нодгруппа без этого лейбла поды не
примет — GPU-ноды (дорогие) исключены из планирования.

## Компоненты и тумблеры

Какой компонент ставить — задаётся в `blueprint.tfvars` (секция «02-addons»):

| Переменная | По умолчанию | Что ставит |
|---|---|---|
| `install_karpenter` | `true` | [Karpenter от Selectel](https://github.com/selectel/karpenter-provider-selectel-docs) (чарт `oci://ghcr.io/selectel/mks-charts/karpenter`) |
| `install_envoy_gateway` | `true` | Envoy Gateway (Gateway API — официально рекомендованный Selectel путь) |
| `install_aibrix` | `true` | AIBrix v0.7.0 (требует Envoy Gateway) |
| `install_litellm` | `true` | LiteLLM Proxy v1.85.1 — auth-слой: virtual keys, бюджеты (требует AIBrix) |
| `install_gpu_operator` | `true` | NVIDIA GPU Operator v26.7.0, classic-режим: драйвер + device plugin + DCGM (требует Karpenter и `installNvidiaDevicePlugin: false` в NodeClass; без оператора GPU-реквесты не работают — драйвера на нодах нет) |
| `install_cert_manager` | `true` | cert-manager v1.21.1 + Selectel DNS01-webhook — TLS Let's Encrypt через DNS-хостинг Selectel (требует домен — см. ниже) |
| `install_external_dns` | `true` | external-dns v0.22.0 + Selectel-webhook — автосоздание DNS-записей для Service/Ingress (требует домен — см. ниже) |
| `install_openwebui` | `true` | OpenWebUI v0.11.3 — веб-морда чата (чарт `helm.openwebui.com`; требует `install_litellm` и `storage_class_name`) |
| `install_n8n` | `true` | n8n 2.38.4 — автоматизации (community-чарт `community-charts.github.io`; требует `storage_class_name`) |
| `install_cnpg` | `true` | CloudNativePG — кластеры PostgreSQL для litellm/n8n/openwebui (кластеры БД — kubectl из `rendered/cnpg-clusters.yaml`) |
| `install_valkey` | `true` | общий valkey (redis) для litellm/n8n/openwebui (чарт `charts.bitnami.com`) |
| `install_dex` | `true` | dex — SSO/OIDC для веб-панелей (OpenWebUI/LiteLLM — нативно, n8n — через Envoy SecurityPolicy; требует домен и `sso_admin_email`) |
| `install_observability` | `true` | Prometheus + Grafana + Alertmanager, OpenSearch + Fluent Bit, ServiceMonitor'ы и дашборды (требует install_dex) |
| `install_csi_s3` | `true` | csi-s3 (geesefs) — монтирование S3-контейнера с весами моделей (требует `create_object_storage=true` в 01-корне; туда же — бэкапы CNPG, `backup_bucket_name`) |
| `deploy_models` | deepseek-r1-distill-llama-8b (пресет `deepseek-r1-distill-llama-8b-s3`) | модели vLLM через чарт inference-charts (веса — из S3): map имя → `{preset, values}`; пресеты `deepseek-r1-distill-llama-8b-s3`, `qwen3-32b-s3` (см. `addons/inference-charts/`; там же справочные пресеты для ручного helm — kimi-k3, llama-3-8b-s3, ray-вариант deepseek, Job'ы s3ModelCopy) |

Версии пиннуты: `karpenter_chart_version = "0.4.0"`, `envoy_gateway_chart_version = "v1.2.8"`, cert-manager `v1.21.1` (чарт из `charts.jetstack.io`, не вендорен), Selectel-webhook `1.4.0` (helm-репо `selectel.github.io`), external-dns `v0.22.0` + Selectel-webhook `v0.2.0` (свой мини-чарт `addons/external-dns-selectel/` — upstream-чарта нет). Чарты AIBrix и LiteLLM вендорены; OpenWebUI `v0.11.3` / чарт `16.5.0` и n8n `2.38.4` / чарт `1.24.40` — из remote-репо (PVC — через переменную `storage_class_name`: имя StorageClass зависит от региона).

## Домен, cert-manager и external-dns (обязательный шаг)

Домен + `install_cert_manager` + `install_external_dns` — обязательная
часть blueprint: от них зависят HTTPS-входы панелей (ai/chat/n8n/auth.
<домен>), SSO через dex и LiteLLM-токены. Автоматизация (A-записи
external-dns, сертификаты cert-manager) замещается ручными действиями
с существенными трудозатратами — ручной вариант не поддерживается.

Выбор — одной переменной `create_zone_and_user` в `blueprint.tfvars`
(в обоих корнях она читается из одного файла).

Регистрация (покупка) домена — всегда вручную, через terraform/API нельзя:
[docs.selectel.ru/domains](https://docs.selectel.ru/domains/)
(заранее пополните баланс на 200 ₽ — минимум для сервиса Домены/DNS-хостинг).
Домен всегда должен быть делегирован на NS Selectel
(`a.ns.selectel.ru … d.ns.selectel.ru`): купленный в Selectel — автоматически,
со стороннего регистратора — смените NS вручную
([docs.selectel.ru/dns-hosting](https://docs.selectel.ru/dns-hosting/)).

### Вариант 1 — `create_zone_and_user = true` (дефолт)

Terraform сам создаёт зону в DNS-хостинге и сервисного пользователя
(роль `member` в проекте кластера; пароль генерируется) — в аккаунте
и проекте кластера. Создание происходит только при ОДНОВРЕМЕННОМ
выполнении: непустой `dns_zone_name` + включённый `install_cert_manager`
или `install_external_dns` (оба выключены — зона/пользователь не создаются,
сертификаты не рендерятся):

```hcl
dns_zone_name = "example.com"
```

01-cluster создаёт `selectel_domains_zone_v2` + `selectel_iam_serviceuser_v1`,
а 02-addons забирает креды из state 01-корня (`terraform_remote_state`) —
копировать outputs руками не нужно.

### Вариант 2 — `create_zone_and_user = false`

Зона и пользователь с доступом к DNS-хостингу уже существуют — в любом
аккаунте Selectel (этом же или отдельном DNS-аккаунте). Заполняются все
переменные (dns_user — роль `member` в проекте зоны, DNS API авторизует
project-scoped токеном):

```hcl
create_zone_and_user = false
dns_zone_name     = "example.com"
dns_user_name     = "dns-automation"
dns_user_password = "..."    # или TF_VAR_dns_user_password
dns_account_id    = "67890"  # ID аккаунта с зоной (панель того аккаунта)
dns_project_id    = "..."    # ID проекта, к которому привязана зона
```

Зона в стороннем (не Selectel) DNS-хостинге — вне рамок blueprint.

### Дальше одинаково для обоих вариантов

- Тумблеры `install_cert_manager` / `install_external_dns` включены по умолчанию —
  заполните dns-переменные и `letsencrypt_email`,
  apply обоих корней (для варианта 1 — 01-cluster первым).
- **Edge-шлюз — единый публичный HTTPS-вход кластера**: один LoadBalancer
  (Envoy Gateway, GatewayClass `edge-eg`) + один wildcard-сертификат
  `*.домен` (Secret `wildcard-tls`, Let's Encrypt DNS-01 через Selectel).
  Порты: 443 — все сервисы `*.домен`, 80 — 301-редирект на https (для любых
  соединений). Все объекты — CRD-ресурсы (инвариант №2): terraform рендерит
  их в `infra/02-addons/rendered/` (email — из `letsencrypt_email`, домен —
  из `dns_zone_name`), применяются kubectl'ом после apply — команда в output
  `cert_apply_command` (паттерн —
  [webinar-llm-on-mks/apps/03](https://github.com/selectel/webinar-llm-on-mks/tree/main/apps/03.cert-manager-external-dns)).
- **Добавить сервис** = новый HTTPRoute на `edge-gw` (пример —
  `addons/cert-manager/manifests/httproute-example.yaml`): указываете хост
  `имя.домен` и бэкенд-сервис; A-запись создаст external-dns (source
  gateway-httproute), TLS уже покрыт wildcard'ом. Свои маршруты храните
  рядом (kubectl apply), terraform'ом рендерится только маршрут LiteLLM
  (host `ai.<домен>` — вычисляется из `dns_zone_name`, отдельно не задаётся).
- Сертификат выпустится только после **делегации домена** на NS Selectel
  (см. выше): DNS-01 челлендж проверяется через публичный DNS.

## Быстрый старт

Значения для ОБОИХ terraform-корней — один файл `blueprint.tfvars` в корне репо
(без дублирования между 01-cluster и 02-addons: каждый корень берёт свои
переменные, лишние игнорирует — будет безобидный Warning "value for undeclared
variable"). При apply файл указывается флагом `-var-file`.

```bash
# 0. Инструменты: terraform >= 1.9, helm >= 3.8, kubectl.
#    Учётные данные Selectel: панель → Профиль → User management → Service users → Пользователь с правами iam.admin.
cp blueprint.tfvars.example blueprint.tfvars   # заполнить креды аккаунта кластера

# 1. Инфраструктура (проект, сеть, кластер, CPU-нодгруппа, kubeconfig)
terraform -chdir=infra/01-cluster init -upgrade
terraform -chdir=infra/01-cluster apply -var-file=../../blueprint.tfvars

# 2.1 Кластеры PostgreSQL (CNPG) — CRD-ресурсы, применяются kubectl
#     ВАЖНО: до этого шага поды litellm/n8n/openwebui не смогут подняться
#     из-за отсутствия баз данных.
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
kubectl apply -f infra/02-addons/rendered/cnpg-clusters.yaml

# 2.2 Компоненты в кластере (тумблеры install_* — в том же blueprint.tfvars)
#    kubeconfig_path и cluster_id — динамические outputs 01-корня, в файл их
#    не пишем: передаём окружением (они required-переменные 02-корня).
terraform -chdir=infra/02-addons init -upgrade
TF_VAR_kubeconfig_path=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path) \
TF_VAR_cluster_id=$(terraform -chdir=infra/01-cluster output -raw cluster_id) \
terraform -chdir=infra/02-addons apply -var-file=../../blueprint.tfvars

#    Секреты можно не хранить в файле, а передавать окружением:
#    TF_VAR_sel_password=... (стандартный механизм Terraform).

# 3. Домен и HTTPS-вход (тумблеры включены по умолчанию; см. «Домен и DNS» выше)
#    В blueprint.tfvars: dns-переменные + letsencrypt_email
#    (+ sso_admin_email для SSO, storage_class_name для OpenWebUI/n8n) → повторить
#    apply шага 2, затем применить отрендеренные манифесты и дождаться wildcard-сертификата:
#      cd infra/02-addons && $(terraform output -raw cert_apply_command)
#      kubectl -n litellm wait certificate/wildcard --for=condition=Ready --timeout=5m
export LITELLM_HOSTNAME=ai.example.com   # ai.<ваш домен из dns_zone_name>

# 4. NodePool'ы GPU — из директории региона кластера (матрица — addons/karpenter/README.md)
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
kubectl apply -f addons/karpenter/selectelnodeclass.yaml
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-l4.yaml          # лёгкие модели
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-rtx4090-48.yaml # 8–32B
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-rtx6000-pro.yaml # 32B+, high RPS
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-h200.yaml       # 70B+ (ru-6)
# кластер в ru-7 — те же команды с директорией addons/karpenter/ru-7/

# 5. Модели — через deploy_models в blueprint.tfvars (terraform, шаг 2);
#    пресеты: addons/inference-charts/values-<preset>.yaml. Веса автоматически
#    загружаются в S3 (Job) и модель стартует с PVC models:
#      deploy_models = { "deepseek-r1-distill-llama-8b" = { preset = "deepseek-r1-distill-llama-8b-s3" } }
kubectl rollout status deployment/deepseek-r1-distill-llama-8b --timeout=30m

#    Публичный вход — https://<litellm_hostname> (edge-шлюз, доступ только
#    по virtual key; управление ключами — addons/litellm/README.md, там же —
#    вариант без домена через kubectl port-forward).
export MASTER=$(kubectl -n litellm get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d)
export KEY=$(curl -s -X POST https://$LITELLM_HOSTNAME/key/generate -H "Authorization: Bearer $MASTER" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"smoke","models":["deepseek-r1-distill-llama-8b"]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
curl https://$LITELLM_HOSTNAME/v1/models -H "Authorization: Bearer $KEY"
curl https://$LITELLM_HOSTNAME/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-r1-distill-llama-8b","messages":[{"role":"user","content":"hello"}]}'
```

Дальше: LoRA-ферма и динамическая загрузка адаптеров — `addons/aibrix/docs/04`,
автоскейлинг по LLM-метрикам — `addons/aibrix/docs/03`, сценарии использования — `addons/aibrix/docs/05`.

## Почему два terraform-корня

Провайдеры `helm`/`kubernetes` не могут зависеть от ресурсов, создаваемых в том же
apply (kubeconfig становится известен только после создания кластера). Поэтому:
`01-cluster` создаёт облако и пишет kubeconfig, `02-addons` подключается к готовому
кластеру по пути из переменной. Это единственный надёжный порядок — не пытайтесь
объединить в один root.

## Почему NodePool'ы применяются kubectl, а не Terraform

`kubernetes_manifest`/`helm` для CRD Karpenter (`SelectelNodeClass`, `NodePool`)
требуют, чтобы CRD уже были зарегистрированы в API-сервере на этапе `plan`.
Сам Karpenter ставится чартом в `02-addons` — CRD появляются только после его
установки. Поэтому манифесты пулов лежат в `addons/karpenter/` и применяются одной
командой `kubectl apply` (это же — путь из документации Karpenter).

## Почему не Envoy AI Gateway (расширение апстрима Envoy Gateway)

Envoy AI Gateway (aigateway.envoyproxy.io) — расширение над Envoy Gateway с CRD
`AIGatewayRoute`/`AIServiceBackend`/`BackendSecurityPolicy` для единой
OpenAI-совместимой точки с маршрутизацией на внешних LLM-провайдеров
(Anthropic/OpenAI и др.), failover'ом и рейт-лимитами по токенам. В этом
репозитории не устанавливается — функциональность уже покрыта двумя слоями:

- LLM-роутинг model→backend — AIBrix gateway + router + ModelAdapter;
- auth к внешним провайдерам, virtual keys, rpm/tpm-лимиты, fallback —
  LiteLLM (`addons/litellm/`);
- ingress по Gateway API — Envoy Gateway (terraform, 02-addons).

Третий envoy-датаплейн дублировал бы оба слоя и добавлял отдельный набор
CRD. Решение пересмотреть, если появится потребность в сквозном
мульти-провайдерном failover'е на уровне шлюза, а не LiteLLM.

## Существенные решения и ограничения

- **Karpenter вместо Cluster Autoscaler**: MKS не разрешает их одновременно;
  в `01-cluster` автоскейлинг и автовосстановление нодгрупп выключены, кластер
  создаётся без `enable_autoscale` (управление нодами — целиком у Karpenter).
- **GPU-ноды** не описаны в Terraform — их создаёт Karpenter из NodePool'ов
  (`addons/karpenter/`), по запросам `nvidia.com/gpu` от Pending-подов.
- **Драйверы GPU** — в этом репозитории их ставит GPU Operator (Karpenter
  провижинит ноды без MKS-стека, автоскейлер MKS выключен). Предустановленные
  драйверы Selectel (device plugin) обязательны только при автоскейлинге
  MKS — с GPU Operator он не работает (инвариант 6 AGENTS.md).
- **Чарт AIBrix вендорен** (`addons/aibrix/chart/`, тег v0.7.0): upstream не публикует
  OCI/helm-репозиторий. Обновление — перезаписать директорию с нового тега,
  CRD отдельно: `kubectl apply -f addons/aibrix/chart/crds/` (helm не обновляет CRD при upgrade).
- **Без RDMA**: мульти-нодовый TP/PP, кросс-нодовый KV-cache и полноценная P/D-дисагрегация
  недоступны — см. `addons/aibrix/docs/01` (карта фич → RDMA). PoC P/D на одной ноде —
  `addons/aibrix/manifests/stormservice-pd-1p1d.yaml`.
- **Сеть подов** должна иметь egress на docker.io, ghcr.io и huggingface.co;
  при блокировках — pull-through-зеркало `docker-registry.selectel.ru`
  (практика этого репо: образы vLLM/утилит в манифестах уже через него).
- Зоны GPU зависят от пула (H100 — ru-7b; A100 40Gb — ru-7a/ru-9a; L4 — ru-6a/ru-7a) —
  сверяйтесь с матрицей доступности Selectel и правьте `values` в `addons/karpenter/*.yaml`.

## Удаление

Простой путь — удалить сразу корень `infra/01-cluster`: вместе с кластером
уходят все аддоны, ноды Karpenter, PVC и Octavia-балансировщики, ничего
внутри кластера чистить и дожидаться не нужно. S3-контейнеры (веса моделей,
бэкапы CNPG) Selectel очищает при удалении контейнера — предварительно
опустошать их не надо.

```bash
# 1) Кластер + аддоны + ноды Karpenter + LB + сеть + S3 + проект
terraform -chdir=infra/01-cluster destroy -var-file=../../blueprint.tfvars

# 2) State 02-корня ссылается на ресурсы удалённого кластера — после разбора
#    он не актуален, просто удаляем файлы (destroy 02 здесь уже невозможен:
#    kubeconfig мёртв вместе с кластером)
rm -f infra/02-addons/terraform.tfstate*

# 3) Остатки terraform: state 01-корня и kubeconfig
rm -f infra/01-cluster/terraform.tfstate* infra/01-cluster/kubeconfig
```

После destroy стоит проверить в панели, что в проекте не осталось плавающих
IP (могут осиротеть при удалении LB — зависит от пула, не проверено на всех).

Если вы удаляете только часть аддонов, но оставляете кластер — это terraform
destroy/apply корня 02 (пока кластер жив и kubeconfig доступен: нужны
`TF_VAR_kubeconfig_path` и `TF_VAR_cluster_id` из outputs 01-корня).

## Статус проверок

- `terraform validate` / `terraform plan`: оба корня, все комбинации тумблеров.
- Чарт AIBrix + values: `helm template` без ошибок (39 объектов, Octavia-аннотации в EnvoyProxy).
- Apply на реальном облаке выполнялся вручную на тестовом проекте (кластер ru-6,
  стек проверен end-to-end: домен/cert-manager/external-dns, SSO, S3-веса,
  LoRA, observability). Автоматизации apply в CI нет — сетевые/квотные вещи
  проверяйте на непроизводственном проекте. Все ссылки на платформенные
  ограничения — в `addons/aibrix/docs/06`.
