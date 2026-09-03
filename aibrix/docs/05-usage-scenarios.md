# 05 — Сценарии использования AIBrix на Selectel MKS

> Предполагается, что AIBrix уже установлен ([docs/02](02-install-mks.md)); переменная `$LB_IP` — внешний IP балансировщика Envoy Gateway:
> ```bash
> LB_IP=$(kubectl get svc -n envoy-gateway-system \
>   -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
> ```

## Сценарий 1. Обслуживание модели: деплой → шлюз (минимум телодвижений)

Обычный Deployment + лейблы — никакого CRD, никакого Service на модель (шлюз сам находит поды по лейблу `model.aibrix.ai/name`; для LoRA-базы Service нужен — см. [docs/04](04-lora-dynamic-loading.md)):

```bash
kubectl apply -f manifests/vllm-quickstart.yaml

curl http://$LB_IP/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"deepseek-r1-distill-llama-8b","messages":[{"role":"user","content":"Привет"}]}'
```

Инвариант: `model.aibrix.ai/name` = `--served-model-name` = имя модели в запросе.

## Сценарий 2. Несколько реплик и умная маршрутизация

Поднимите `replicas: N` у Deployment (или включите [автоскейлинг](#сценарий-4-инференс-автоскейлинг)). Алгоритм выбирается заголовком **`routing-strategy`** в запросе (по умолчанию `random`):

| Алгоритм | Когда применять |
|---|---|
| `random` | дефолт, для равномерной размазки |
| `least-request` | наименьшее число параллельных запросов — рабочая лошадка |
| `least-busy-time` | наименьшая занятость пода по времени |
| `least-latency` | минимальная наблюдаемая латентность (нужны метрики) |
| `least-kv-cache` / `least-gpu-cache` | минимальная заполненность KV/GPU-кэша пода |
| `least-utilization` | минимальная утилизация |
| `throughput` | максимум throughput пода |
| `prefix-cache` | роутинг по совпадению префикса промпта с KV-кэшем — меньше recompute для повторяющихся преамбул (RAG, системные промпты) |
| `power-of-two` | выбор из двух случайных подов — дешёвая защита от «перегретого» пода |
| `session-affinity` | sticky-сессии: тот же pod по заголовку `x-session-id` |
| `vtc-basic` | fairness между пользователями |
| `slo`, `slo-pack-load`, `slo-least-load`, `slo-least-load-pulling` | SLO-aware выбор пода (P99 TTFT/TPOT) — обычно вместе с gpu-optimizer |
| `pd` | P/D-дисагрегация — полный кросс-нодовый вариант требует RDMA, механика и single-node PoC — [Сценарий 8](#сценарий-8-pd-дисагрегация-распределённые-prefill-и-decode) |

```bash
curl http://$LB_IP/v1/chat/completions -H "Content-Type: application/json" \
  -H "routing-strategy: prefix-cache" \
  -d '{"model":"...","messages":[...]}'
```

Часть стратегий (латентности/утилизации) опирается на метрики: шлюз скрейпит поды сам (`AIBRIX_POD_METRIC_REFRESH_INTERVAL_MS=50` дефолтом чарта), а для внешних метрик нужен Prometheus-эндпоинт — деталь в [gateway docs](https://aibrix.readthedocs.io/latest/features/gateway-plugins.html). Session-affinity: добавьте свой заголовок `x-session-id: <id пользователя/сессии>`.

## Сценарий 3. LoRA-ферма: много дешёвых моделей на одном пуле GPU

Полный гайд — [docs/04](04-lora-dynamic-loading.md). Суть: одна база (например, Qwen2.5-Coder-1.5B) + N адаптеров на тех же подах:

```bash
kubectl apply -f manifests/vllm-lora-base.yaml
kubectl apply -f manifests/lora-adapter.yaml

# Клиент видит «модели»: базу и каждый адаптер — одинаковым API:
curl http://$LB_IP/v1/models/          # qwen-coder-1-5b-instruct, qwen-code-lora, ...
```

- плотность регулируется флагами `--max-loras`/`--max-cpu-loras` на vLLM;
- несколько адаптеров = несколько CR ModelAdapter (пример из upstream: [adapter-multi-lora.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/adapter/adapter-multi-lora.yaml));
- `schedulerName: least-adapters` распределяет адаптеры по подам равномерно;
- хранение своих адаптеров: приватный HF-репозиторий или S3 (в Selectel — Object Storage, `artifactURL: s3://...` + `credentialsSecretRef` + runtime-сайдкар).

Экономика: адаптер 70 МБ против отдельного деплоя модели 3+ ГБ — на одном GPU крутятся десятки доменных «моделей».

## Сценарий 4. Инференс-автоскейлинг

KPA по утилизации KV-cache — `manifests/podautoscaler-kpa.yaml` (готов к применению):

```bash
kubectl apply -f manifests/podautoscaler-kpa.yaml
kubectl get podautoscaler qwen-coder-1-5b-instruct-kpa -w
```

Полный разбор совместимости с автоскейлером Selectel (CA), аннотации, оговорки и бюджет холодного старта — [docs/03](03-autoscaling.md). Кратко: KPA/APA работают; Prometheus и metrics-server не нужны; сцепка «KPA → поды → CA → GPU-ноды» компонуется, холодный старт GPU-ноды — минуты, держите минимум одну ноду тёплой.

## Сценарий 5. Наблюдаемость

- **Метрики:** runtime-сайдкар стандартизует метрики движков (vLLM/SGLang/TRT-LLM) на :8080 — TTFT, TPOT, длины очередей, токены/с. Service модели уже несёт аннотации `prometheus.io/scrape` (см. наш манифест базы).
- **Prometheus:** поставьте `kube-prometheus-stack`, включите в values `prometheus.enable: true` (ServiceMonitor для controller-manager; для gateway-plugins метрики на :8080 с аннотациями — ServiceMonitor свой по образцу). Grafana-дашборды лежат в [observability/grafana/](https://github.com/vllm-project/aibrix/tree/v0.7.0/observability/grafana) репозитория — импортируйте JSON.
- **Трейсинг (opt-in):** блок `openTelemetry` в values → ваш OTLP-endpoint (например, самостоятельно развёрнутый otel-collector; Jaeger/otel в комплекте AIBrix нет с v0.3+).

## Сценарий 6. Rate limiting и учёт токенов

Шлюз с metadata-service дают:

- лимиты **RPM/TPM на пользователя** и RPS на модель (состояние — в Redis);
- подсчёт токенов, в том числе в **стриминге** (usage в SSE);
- управление пользователями через API metadata-service ([gateway docs → Rate Limiting](https://aibrix.readthedocs.io/latest/features/gateway-plugins.html)).

## Сценарий 7. Мульти-движки и гетерогенные GPU

- **Мульти-движки:** vLLM, SGLang, TensorRT-LLM за одним шлюзом — лейбл `model.aibrix.ai/engine` на Deployment (дефолт `vllm`). Миграция с vLLM на TRT-LLM для латентностно-критичных моделей — без смены клиентского API.
- **Гетерогенные GPU (экспериментально):** одна модель на разных типах GPU-нодгрупп (например, часть трафика на L4 — дешевле, часть на A100 — быстрее); шлюз трейсит запросы, gpu-optimizer подбирает тип GPU под SLO.

## Сценарий 8. P/D-дисагрегация: распределённые prefill и decode

> **Статус:** механика и манифесты — по докам/сэмплам v0.7.0 (проверено). Для кластера **без RDMA** полноценный кросс-нодовый вариант недоступен — честный разбор в §8.5; что можно попробовать — single-node PoC (§8.5, готовый манифест `manifests/stormservice-pd-1p1d.yaml`).

### 8.1. Зачем разделять prefill и decode

Две фазы инференса нагружают GPU по-разному:

- **prefill** (обработка промпта) — compute-bound: параллельная матричная математика;
- **decode** (потоковая генерация токенов) — memory-bound: упирается в пропускную способность GPU-памяти и размер KV-cache.

Разнос фаз на разные поды даёт: меньше TTFT при длинных промптах (decode не ждёт, пока на том же GPU считают чужой префилл), утилизацию decode-GPU ближе к 100%, независимое масштабирование фаз. Эффект максимальный на длинных промптах (RAG, большие системные инструкции) — что и подтверждает документация: «Particularly effective for long prompts or workloads dominated by heavy prompt processing».

### 8.2. Как это устроено в AIBrix (v0.7.0)

**Оркестрация — CRD `StormService`** (3 слоя: StormService → RoleSet → поды; Ray не нужен):

| Режим | Когда `spec.replicas` | Поведение |
|---|---|---|
| **Replica mode** | > 1 | Каждый RoleSet — независимая копия сервиса с фиксированным P/D-рацио; масштабирование целыми RoleSet |
| **Pooled mode** | = 1 | Роли (prefill, decode) — раздельные пулы, масштабируются **независимо** друг от друга |

**Маршрутизация.** Шлюз узнаёт роль пода по лейблам (генерируются контроллером StormService):

| Лейбл | Значение | Смысл |
|---|---|---|
| `role-name` | `prefill` \| `decode` | Фаза; standard-поды (без PD) этот лейбл не имеют |
| `roleset-name` | например `group-0` | Пара «prefill+decode»: шлюз использует только RoleSet'ы, где есть **оба** пода |

Поток запроса: шлюз → **prefill-под** (считает KV-cache) → **трансфер KV** на decode-под → decode стримит токены клиенту. Если подходящей пары нет (вне бакетов по длине промпта, все пары заняты) — **fallback на standard-поды** (обычный Deployment той же модели: обе фазы на одном GPU). Standard-поды опциональны и служат «предохранителем» — их можно добавлять к PD-топологии без изменения клиентского кода.

**Движки и KV-транспорт:**

| Движок | Транспорт KV | Примечание |
|---|---|---|
| vLLM | **NIXL** (NixlConnector) | официальный сэмпл: `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`, enhanced-образ `aibrix/vllm-openai:...-nixl-...` |
| SGLang | nixl; **Mooncake** — опция (`--disaggregation-transfer-backend=mooncake`) | README сэмплов: «mooncake **requires RDMA** to work» |
| TensorRT-LLM | NIXL (`AIBRIX_KV_CONNECTOR_TYPE=nixl`) | gateway-коннектор |

**Тюнинг шлюза** (env gateway-plugins, дефолты из доков): `AIBRIX_PROMPT_LENGTH_BUCKETING=false` (бакетинг по длине промпта), `AIBRIX_PREFILL_SCORE_POLICY=prefix_cache` / `AIBRIX_DECODE_SCORE_POLICY=load_balancing`, `AIBRIX_PREFILL_REQUEST_TIMEOUT=30`, `AIBRIX_KV_CONNECTOR_TYPE=shfs` (дефолт gateway-коннектора).

### 8.3. Развертывание (по официальному сэмплу v0.7.0)

Основа — [samples/quickstart/pd-model.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/quickstart/pd-model.yaml): StormService `vllm-1p1d` (pooled mode, `spec.replicas: 1`), внутри две роли с enhanced-образом vLLM и NIXL:

```yaml
apiVersion: orchestration.aibrix.ai/v1alpha1
kind: StormService
metadata:
  name: vllm-1p1d
spec:
  replicas: 1                # pooled mode: роли масштабируются независимо
  updateStrategy: { type: InPlaceUpdate }
  stateful: true
  template:
    metadata:
      labels: { app: vllm-1p1d }
    spec:
      roles:
        - name: prefill       # роль 1
          replicas: 1
          template:
            metadata:
              labels: { model.aibrix.ai/name: deepseek-r1-distill-llama-8b, model.aibrix.ai/port: "8000", model.aibrix.ai/engine: vllm }
            spec:
              containers:
                - name: prefill
                  image: aibrix/vllm-openai:v0.9.2-cu128-nixl-v0.4.1   # enhanced-образ с NIXL
                  args:
                    - |
                      vllm serve --host "0.0.0.0" --port "8000" \
                        --model deepseek-ai/DeepSeek-R1-Distill-Llama-8B \
                        --served-model-name deepseek-r1-distill-llama-8b \
                        --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
                  # + env VLLM_NIXL_SIDE_CHANNEL_HOST/PORT, UCX_TLS, securityContext: IPC_LOCK
        - name: decode         # роль 2 — аналогично
          ...
```

Обращение — заголовком на каждый запрос, либо сделать `pd` дефолтом модели аннотацией (рекомендуется для прода):

```bash
# per-request:
curl http://$LB_IP/v1/chat/completions -H "Content-Type: application/json" \
  -H "routing-strategy: pd" \
  -d '{"model":"deepseek-r1-distill-llama-8b","messages":[{"role":"user","content":"Напиши эссе про KV-cache"}]}'
```

```yaml
# дефолт для модели — аннотация в pod template:
metadata:
  annotations:
    model.aibrix.ai/config: |
      { "profiles": { "default": { "routingStrategy": "pd" } } }
```

Ссылки на полный набор сэмплов: [disaggregation/vllm](https://github.com/vllm-project/aibrix/tree/v0.7.0/samples/disaggregation/vllm) (`1p1d.yaml`, `pool.yaml`, статический вариант через upstream `disagg_proxy_server.py`) и [disaggregation/sglang](https://github.com/vllm-project/aibrix/tree/v0.7.0/samples/disaggregation/sglang) (`tp-1p1d.yaml`, бакетинг).

### 8.4. По-ролевое масштабирование (pooled mode)

Разные фазы — разные метрики и лимиты: PodAutoscaler с `subTargetSelector` на конкретную роль StormService ([samples/autoscaling/stormservice-pool.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/autoscaling/stormservice-pool.yaml)):

```yaml
apiVersion: autoscaling.aibrix.ai/v1alpha1
kind: PodAutoscaler
metadata:
  name: ss-pool-prefill
  annotations:
    autoscaling.aibrix.ai/storm-service-mode: "pool"   # обязателен для pooled mode
spec:
  scaleTargetRef:
    apiVersion: orchestration.aibrix.ai/v1alpha1
    kind: StormService
    name: ss-pool
  subTargetSelector:
    roleName: prefill          # ← целевая роль
  minReplicas: 2
  maxReplicas: 20
  scalingStrategy: APA
  metricsSources:
    - metricSourceType: pod
      protocolType: http
      port: "8000"
      path: /metrics
      targetMetric: "prefill_queue_length"   # метрика фазы префилла
      targetValue: "10"
# ... и второй PodAutoscaler для decode (например, по decode_batch_utilization)
```

Дальше та же сцепка с CA Selectel, что описана в [docs/03](03-autoscaling.md) — только масштабируются не «модели», а фазы.

### 8.5. Что реально на кластере без RDMA (честный разбор)

| Слой | Работает без RDMA? | Комментарий |
|---|---|---|
| Оркестрация StormService (роли, апдейты, replica/pooled) | ✅ | обычные Kubernetes-механики |
| Маршрутизация шлюза (пейринг по `roleset-name`, `routing-strategy: pd`, fallback, бакетинг) | ✅ | чистая CPU-логика gateway-plugins |
| **Кросс-нодовый трансфер KV** | ❌ | документированный путь — «high-speed interconnect»; сэмплы под кросс-нод заточены под RDMA-CNI (в 1p1d.yaml — pod-networks от Volcano Engine); Mooncake «requires RDMA» по README сэмплов |
| **Single-node PD (пара подов на одной ноде)** | ⚠️ не документировано | статуса «предположение»: NIXL/UCX технически умеет node-local транспорты (posix/sm/TCP), но AIBrix этот путь не документирует и не тестирует. Нужен PoC |

**Наш single-node PoC-манифест:** [`manifests/stormservice-pd-1p1d.yaml`](../manifests/stormservice-pd-1p1d.yaml) — официальный сэмпл 1p1d + `podAffinity`, привязывающий пару prefill/decode к **одной ноде** (чтобы трансфер KV шёл через node-local транспорт, а не через сеть). Это самый дешёвый способ проверить саму механику P/D на MKS.

Дополнительные оговорки для PoC:

- в сэмплах подам нужна capability **IPC_LOCK** (`securityContext`) — поддержка capabilities в MKS в документации не подтверждена (см. [docs/06](06-selectel-mks-notes.md)); проверьте на тесте;
- enhanced-образ `aibrix/vllm-openai:...-nixl-...` тянется с Docker Hub — при закрытом egress настройте мирринг;
- env-блок сэмпла (`NCCL_IB_*`, `UCX_TLS=^gga`) откалиброван под облако вендора — для PoC без IB это отправная точка, а не истина: логи `NCCL_DEBUG=INFO` покажут, какой транспорт реально поднялся;
- итог PoC-критерий: запрос через `routing-strategy: pd` возвращает ответ, логи vLLM показывают трансфер KV, latency не деградирует относительно standard-подов.

### 8.6. Если в кластере появится RDMA

Рецепт не меняется — добавляется инфраструктура: нодгруппы с InfiniBand/RoCE, CNI с RDMA-подсетями (как в сэмплах), затем тот же StormService + NIXL/Mooncake + по-ролевое масштабирование, но уже с кросс-нодовым трансфером. Всё описанное в §8.2–8.4 останется без изменений — меняется только транспортный слой.

## Чего НЕ делать на кластере без RDMA

| Фича | Почему нет |
|---|---|
| Ray-мульти-нодовый инференс (RayClusterFleet/RayClusterReplicaSet, TP/PP между нодами) | быстрый интерконнект — суть сценария; плюс мы KubeRay не ставили |
| KV-cache offloading **L2** / cross-engine reuse (InfiniStore, HPKV...) | коннектор InfiniStore по умолчанию — RDMA |
| PD-дисагрегация с кросс-нодовым KV-трансфером | транспорт NIXL/UCX собирается под RDMA в enhanced-образах AIBrix; механика и single-node PoC — см. [Сценарий 8](#сценарий-8-pd-дисагрегация-распределённые-prefill-и-decode) |

KV **L1** (DRAM-оффлоад в память пода) работает и без RDMA, но требует enhanced-образа vLLM от AIBrix (`aibrix/vllm-openai:*`, см. [container images](https://aibrix.readthedocs.io/latest/getting_started/container-images.html)) — для теста не обязательно.

## Production-заметки (когда пойдёт в прод)

1. **HA шлюза:** `gatewayPlugin.replicaCount: 2+` **и** `AIBRIX_STATESYNC_ENABLED: "true"` в env (синхронизация prefix-cache между репликами через Redis — без этого реплики будут конкурировать). `gateway.envoyProxy.replicas: 2`.
2. **Redis:** встроенный — без персистенса (умер → потерялись счётчики rate-limit и профили). Для прода — внешний управляемый Redis (тогда `metadata.redis.enabled: false` + host'ы во всех трёх местах, см. values) и sizing ~1 GiB на 1000 параллельных запросов (ориентир из production-доков).
3. **Таймауты:** `controllerManager.gatewayTimeoutSeconds` (дефолт 120 с) и `gateway.envoyPatchPolicy.route.timeout` — поднимите для длинных генераций; таймауты Octavia уже выставлены в values (1 ч).
4. **Изоляция данных плейна:** Envoy по умолчанию имеет anti-affinity от GPU-нод (остаётся на CPU-нодгруппе) — не убирайте, GPU дорогие.
5. **Обновления моделей:** vLLM-под с моделью — минуты загрузки; используйте `startupProbe` (как в наших манифестах) и `terminationGracePeriodSeconds` побольше для докачки стримов.

## Источники

- [Gateway Plugins (routing, rate limiting, observability)](https://aibrix.readthedocs.io/latest/features/gateway-plugins.html) · [Production: Gateway](https://aibrix.readthedocs.io/latest/production/gateway.html) · [Observability](https://aibrix.readthedocs.io/latest/production/observability.html) · [Container images](https://aibrix.readthedocs.io/latest/getting_started/container-images.html) · [Multi-engine](https://aibrix.readthedocs.io/latest/features/multi-engine.html) · [Heterogeneous GPU](https://aibrix.readthedocs.io/latest/features/heterogeneous-gpu.html)
