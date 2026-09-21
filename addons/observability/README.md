# Observability: метрики, логи, дашборды, алерты

Umbrella-чарт `chart/` (из апстрим-папки `ai-ml-observability` +
дополнения Selectel MKS). Ставит **terraform** (тумблер `install_observability`
в blueprint.tfvars, корень 02-addons). Требует `install_dex` (OIDC-вход Grafana)
и домен (`dns_zone_name`).

## Состав

| Компонент | Что даёт |
|---|---|
| kube-prometheus-stack (88.6.3) | Prometheus + Alertmanager + Grafana, дефолтные k8s-метрики и алерты, дашборды k8s-views |
| opensearch-operator + OpenSearchCluster | хранение логов (2×5Gi) |
| fluent-operator (Fluent Bit) | сбор логов подов → OpenSearch (индекс `fluent-bit`) |
| DCGM | **не ставится чартом** — экспортер уже ставит GPU Operator (daemonset `nvidia-dcgm-exporter`, ns gpu-operator); чарт добавляет только ServiceMonitor |

## Что собираем (метрики)

- **vLLM** — ServiceMonitor `vllm` по лейблу сервиса `observability.ai/vllm: "true"`
  (добавлен в манифесты моделей `addons/models/`), порт `metrics`.
- **AIBrix** — gateway-plugin `:8080/metrics` (запросы/ошибки по моделям, токены,
  латентность шлюза) + контроллер `:8080/metrics` — обычный HTTP, без
  kube-rbac-proxy (ServiceMonitor рендерит сам чарт aibrix,
  `prometheus.enable: true`; в v0.7.0 — с локальным патчем, см.
  `addons/aibrix/chart/templates/prometheus/monitor.yaml`) + Envoy data-plane
  `:19001/stats/prometheus` (PodMonitor `envoy-aibrix-dataplane`, поды Gateway
  `aibrix-eg` в ns envoy-gateway-system).
- **LiteLLM** — `/metrics:4000`, включается `litellm_settings.callbacks:
  ["prometheus"]` (уже в `addons/litellm/values-selectel-mks.yaml.tpl`).
- **CNPG (Postgres)** — PodMonitor'ы создаёт сам оператор CNPG
  (`monitoring.enablePodMonitors: true` в `addons/cnpg/manifests/clusters.yaml.tpl`).
- **n8n** — `/metrics:5678`, ServiceMonitor и env `N8N_METRICS=true` рендерит
  сам чарт n8n (`serviceMonitor.enabled` в values).
- **GPU (DCGM)** — ServiceMonitor `nvidia-dcgm-exporter` создаёт сам чарт
  GPU Operator (ns gpu-operator); Prometheus его подбирает автоматически
  (свой из чарта observability отключён, чтобы не конфликтовал).
- **NodePool**: компоненты стека (кроме daemonset'ов node-exporter и
  fluent-bit, которые обязаны быть на всех нодах) пиннятся на выделенные
  CPU-ноды Karpenter: `addons/karpenter/ru-<регион>/nodepool-monitoring.yaml`
  (taint `dedicated=monitoring`, применяется kubectl'ом).
- **OpenWebUI** — ⚠ нативного Prometheus-эндпоинта НЕТ (только OTel-экспорт в
  сторонний коллектор, в этот стек не входит). Доступность UI видна по
  дефолтным k8s-метрикам (поды/рестарты), HTTP-активность — по метрикам Envoy.

## Дашборды (Grafana, sidecar подхватывает по лейблу grafana_dashboard=1)

- `ray-vllm-inference-dashboard` — vLLM (апстрим-чарт)
- `litellm-dashboard` — официальный LiteLLM Proxy (из репозитория litellm)
- `dcgm-exporter-dashboard` — GPU (NVIDIA dcgm-exporter)
- `cnpg-dashboard` — официальный CloudNativePG (grafana.com **20417**, rev 4)
- `n8n-dashboard` — n8n Workflow & Execution Analytics (grafana.com **24475**;
  читает БД n8n напрямую через SQL — датасорс `n8n-postgres`, см. ниже)
- `aibrix-control-plane-dashboard`, `aibrix-envoy-gateway-dashboard`,
  `aibrix-vllm-engine-dashboard` — официальные дашборды AIBrix
  (тег v0.7.0, `observability/grafana/` репозитория vllm-project/aibrix;
  ModelClaim Runtime из main не берём — в v0.7.0 его нет)
- стандартные k8s-дашборды kube-prometheus-stack

Во всех сторонних JSON при импорте: удалены `id`/`__inputs`/`__requires`,
ссылки `${DS_*}` заменены на фикс. uid (`prometheus` / `n8n-postgres`),
шаблонная переменная-источник датасорса зафиксирована.

### Датасорс n8n-postgres (SQL-дашборд 24475)

Дашборд 24475 не использует Prometheus: 22 SQL-запроса к БД n8n. Поэтому чарт
создаёт Postgres-датасорс `n8n-postgres` (`n8n-db-rw.n8n:5432`, БД `n8n`,
пользователь `app`), пароль — env `N8N_DB_PASSWORD` пода Grafana из Secret
`n8n-db-readonly` в ns monitoring. Secret — копия операторного
`n8n-db-app` (ns n8n): terraform читает его data-источником и копирует
(Prometheus/Grafana читают секреты только своей namespace). При пересоздании
кластера n8n-db копия обновится при следующем apply.

Грабли, найденные при импорте (актуально для будущих дашбордов):

- **Легаси-поле `id`** в JSON дашборда → Grafana 12 при провижининге:
  «deprecatedInternalID already in use». Поле удаляем.
- **Смена uid JSON в том же файле** (замена самописного дашборда официальным
  с тем же именем CM) → старый uid остаётся «provisioned» и конфликтует
  по internal-ID. Лечится: удалить CM дашборда, подождать удаления
  сайдкаром (~1 мин), вернуть CM.
- **Файл дашборда должен называться `<имя>-dashboard.json`** — шаблон
  `extra.yaml` подставляет суффикс в путь `.Files.Get`; при несовпадении
  helm молча рендерит пустой CM (пустая графа данных, EOF в логах grafana).

## Алерты (PrometheusRule `ai-workloads`)

GPU: XID-ошибки (critical), перегрев >90°C (warning). vLLM: очередь запросов,
KV-кэш >95%, прерывания (preemption). LiteLLM: ошибки прокси. AIBrix: ошибки
шлюза по модели. CNPG: лаг репликации, экспортер метрик недоступен.
Остальное (узел вниз, CrashLoop, PVC) — дефолтные правила kube-prometheus-stack.

## OpenSearch Dashboards (web-UI для логов)

Включается в `OpenSearchCluster.spec.dashboards` (values `opensearch.dashboards`):
оператор ставит Deployment+Service `opensearch-dashboards` (версия = версии
OpenSearch). Публичный адрес — `https://osd.<домен>` (HTTPRoute применяется
kubectl'ом, как у grafana).

- **Вход**: пользователь `dashboard_user` (readall, создаётся в
  security-config вместе с кластером), пароль — Secret
  `opensearch-dashboard-credentials` в ns monitoring:
  ```bash
  kubectl -n monitoring get secret opensearch-dashboard-credentials     -o jsonpath='{.data.password}' | base64 -d; echo
  ```
- **Как смотреть логи**: Discover → выбрать index pattern `fluent-bit`
  (единственный индекс fluent-bit, без суффиксов) → фильтры по
  `kubernetes.namespace_name`, `kubernetes.pod_name` и т.д.; поле времени —
  `@timestamp`, сообщение — `log`. В Grafana тот же индекс доступен через
  datasource OpenSearch (Explore), но Discover в Dashboards удобнее для
  именно логов.
- Серверная часть дашбордов подключается к OpenSearch под admin (Secret
  `opensearch-admin-credentials`, тот же, что у Grafana-датасорса);
  UI-пользователь входит своими (dashboard_user) — они независимы.

### OIDC-вход через dex

Включается values `opensearch.oidc` (terraform подставляет домен и
client_secret; dex-клиент `opensearch-dashboards` — в
`addons/dex/manifests/config.yaml.tpl`). Два конца:

- **OpenSearch (security-плагин)**: `config.yml` в security-config с
  auth-доменами `basic_internal` (order 0) + `openid_dex` (order 1);
  subject_key — **`name`** (dex staticPasswords НЕ отдаёт
  `preferred_username` в ID-токене; `name` = username пользователя dex).
  Пользователи OIDC маппятся в `roles_mapping`: `all_access.users: ["admin"]`
  (проверено: сохранённые объекты создаёт, полный доступ).
- **Dashboards**: `OpenSearchCluster.spec.dashboards.additionalConfig` —
  multiauth `["basicauth", "openid"]`, логин-страница показывает обе опции:
  «Log in with SSO» (dex: email + SSO-пароль) и локальный вход
  (dashboard_user).

Грабли (проверено 2026-09-14):

- **Redirect URI dex — `/auth/openid/login`**, не `/auth/openid/callback`
  (OPENID_AUTH_LOGIN в security-dashboards 2.19).
- **Изменения security-config применяет оператор при rolling-restart
  кластера** — но не раньше, чем кластер green (`drainDataNodes: true`).
  API `PATCH securityconfig` отдаёт FORBIDDEN. Практика: обновить Secret
  `opensearch-security-config` → дождаться green → оператор перекатит ноды
  сам (или удалить поды руками).
- **Новые ноды Karpenter**: CNI/DNS прогревается ~3–4 мин — Dashboards при
  старте не резолвят dex и падают FATAL («Failed to obtain the endpoints
  from your IdP»); лечится рестартом пода после прогрева ноды.

## Вход в Grafana

- **OIDC (основной)**: «Dex SSO» на `https://grafana.<домен>` — любой
  пользователь dex получает роль Viewer (админ — локальный логин).
  Клиент `grafana` в dex (`addons/dex/manifests/config.yaml.tpl`),
  client_secret — общий (Secret `grafana-oauth` в ns monitoring).
- **Локальный админ**: пароль в Secret `kube-prometheus-stack-grafana`
  (генерируется terraform, state не в репо):
  ```bash
  kubectl -n monitoring get secret kube-prometheus-stack-grafana \
    -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

## Установка и проверка

Terraform (тумблер) ставит чарт; HTTPRoute — рендер + kubectl (инвариант №2):

```bash
# 1) terraform (install_observability=true)
terraform -chdir=infra/02-addons apply -var-file=../../blueprint.tfvars

# 2) публичные адреса grafana.<домен> и osd.<домен>
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
kubectl apply -f infra/02-addons/rendered/httproute-grafana.yaml
kubectl apply -f infra/02-addons/rendered/httproute-osd.yaml

# 3) проверка: все цели UP
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
# открыть http://localhost:9090/targets — vllm, litellm, n8n, aibrix,
# dcgm, cnpg (cnpg-*), node-exporter, kube-state-metrics
```

Открыть `https://grafana.<домен>` → «Dex SSO».

## Известные ограничения

- **CRD OpenSearch не обновляются при `helm upgrade`** (helm не трогает
  `crds/` при upgrade — то же ограничение, что у aibrix): при смене версии
  opensearch-operator обновить `kubectl apply -f chart/crds/`.
- `dependency_update=true` в helm_release: сабчарты скачиваются при каждом
  apply (пины версий — в `chart/Chart.lock`).
- PVC суммарно ~17Gi (fast2.<регион>): Prometheus 5Gi, Alertmanager 1Gi,
  Grafana 1Gi, OpenSearch 2×5Gi. StorageClass передаётся переменной
  `storage_class_name`.
- Grafana `assertNoLeakedSecrets`: client_secret OIDC передаётся env'ом из
  Secret (не через values) — иначе grafana-чарт блокирует рендер.
- OpenSearch-пароли: только alnum (плагин безопасности отклоняет часть
  спецсимволов).

## Синхронизация с апстримом

Папка происходит из апстрим-репозитория (`ai-ml-observability`, коммит
«add ai-ml observability stack»). Наши дополнения при обновлении переносить
вручную: `templates/endpoints/{litellm,aibrix,dcgm}-servicemonitor.yaml`,
`templates/endpoints/envoy-podmonitor.yaml`,
`templates/datasources/n8n-postgres.yaml`,
`templates/rules/ai-workloads.yaml`, `templates/dashboards/extra.yaml`,
`files/dashboards/*-dashboard.json`, секции
`endpoints.*`/`n8nDatasource`/`rules` в `chart/values.yaml`.
