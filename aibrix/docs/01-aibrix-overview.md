# 01 — AIBrix: компоненты, фичи и карта зависимостей от RDMA

> Версия, на которую пиннится весь пакет: **AIBrix v0.7.0** (релиз 2026-06-16, тег-коммит [`c546589`](https://github.com/vllm-project/aibrix/commit/c5465890951ad43d22241ab7ed964b929c5d4aba)).
> Статус фактов: всё ниже проверено по манифестам релиза, Helm-чарту `dist/chart` и официальной документации (см. [Источники](#источники)).

## 0. Соответствие версий и документации (важно)

| Артефакт | Версия | Примечание |
|---|---|---|
| Последний стабильный релиз | **v0.7.0** (2026-06-16) | 242 PR: Console (preview), Batch API, мульти-движки (vLLM/SGLang/TensorRT-LLM), KV-cache-центричная P/D-дисагрегация, HA-шлюз |
| [aibrix.readthedocs.io/latest](https://aibrix.readthedocs.io/latest/) | **ветка main (post-v0.7.0)** | Например, страница [ModelClaim](https://aibrix.readthedocs.io/latest/features/modelclaim.html) существует только в main — в теге v0.7.0 её нет. Всё в этом пакете сверено с тегом v0.7.0 |
| Установочные манифесты релиза | `aibrix-dependency-v0.7.0.yaml`, `aibrix-core-crds-v0.7.0.yaml`, `aibrix-core-v0.7.0.yaml` | [Страница релиза](https://github.com/vllm-project/aibrix/releases/tag/v0.7.0) |
| Helm-чарт | `dist/chart` в репозитории, chart version 0.7.0 | ⚠️ Не публикуется в Helm-репозиториях/OCI — установка из git-клона тега |

## 1. Что такое AIBrix (и при чём тут ai-on-eks)

**AIBrix** ([vllm-project/aibrix](https://github.com/vllm-project/aibrix), Apache-2.0) — open-source «строительные блоки» для LLM-инференса на Kubernetes: шлюз с LLM-aware-маршрутизацией, inference-shaped автоскейлинг, динамическая загрузка LoRA, оркестрация распределённого инференса и KV-cache. Upstream-проект vLLM.

Репозиторий [`awslabs/ai-on-eks`](https://github.com/awslabs/ai-on-eks), на который вы ссылались, **не форкает и не модифицирует AIBrix** — он подключает манифесты upstream-репозитория напрямую через ArgoCD-приложения (`repoURL: https://github.com/vllm-project/aibrix.git`):

- [aibrix-core.yaml](https://github.com/awslabs/ai-on-eks/blob/main/infra/base/terraform/argocd-addons/aibrix-core.yaml) → `path: config/overlays/release`, namespace `aibrix-system`; патчит Envoy Service LoadBalancer → ClusterIP (для сценариев без публичного LB);
- [aibrix-dependency.yaml](https://github.com/awslabs/ai-on-eks/blob/main/infra/base/terraform/argocd-addons/aibrix-dependency.yaml) → `path: config/dependency/envoy-gateway`, namespace `envoy-gateway-system`;
- включается флагом `enable_aibrix_stack` (по умолчанию `false`), версия — переменной `aibrix_stack_version`, **в ai-on-eks запиннена v0.4.1** — три минорные версии позади v0.7.0.

**Вывод:** на Selectel MKS разворачивается всё то же самое из `vllm-project/aibrix` v0.7.0; ai-on-eks добавляет только EKS-специфичный Terraform/ArgoCD-клей и устаревший пин версии. Разворачивать нужно upstream.

## 2. Компоненты, появляющиеся после установки

### 2.1. Namespace `aibrix-system`

| Deployment | Образ (v0.7.0) | Роль |
|---|---|---|
| `aibrix-controller-manager` | `aibrix/controller-manager:v0.7.0` | Единый Go-бинарь со **всеми** контроллерами: pod-autoscaler, distributed-inference (Ray), model-adapter (LoRA), kv-cache, stormservice. Плюс admission-webhooks и встроенный cert-rotator |
| `aibrix-gateway-plugins` | `aibrix/gateway-plugins:v0.7.0` | Дата-плейн: Envoy Gateway **ext_proc**-расширение (gRPC :50052) — все routing-алгоритмы, rate limiting, учёт токенов |
| `aibrix-metadata-service` | `aibrix/metadata-service:v0.7.0` | Реестр моделей, user-management (квоты RPM/TPM), OpenAI-совместимый **Batch API** (:8090) |
| `aibrix-gpu-optimizer` | `aibrix/runtime:v0.7.0` (helm stable) | Оптимизатор: офлайн-профилирование GPU↔модель, рекомендации числа реплик по SLO/стоимости |
| `aibrix-redis-master` | `redis:7.4` | Общее состояние: rate-limit счётчики, синхронизация реплик шлюза, профили оптимизатора |
| `aibrix-kuberay-operator`¹ | `aibrix/kuberay-operator:v1.2.1-patch-20250726` | KubeRay-оператор для Ray-кластеров (распределённый инференс). **Функционально опционален** — без Ray CRD контроллер distributed-inference просто не стартует |

¹ Входит во все-in-one манифест `aibrix-core-v0.7.0.yaml` (kustomize-путь), но **не входит в Helm-чарт** — при установке через Helm KubeRay не ставится вовсе (проверено рендером: 5 Deployment). Для нашего сценария (без RDMA) KubeRay не нужен в любом виде.

Плюс нерабочие объекты: `GatewayClass aibrix-eg`, `Gateway aibrix-eg`, HTTPRoute'ы `aibrix-reserved-router*`, `EnvoyProxy aibrix-custom-proxy-config`, политики `EnvoyPatchPolicy`/`EnvoyExtensionPolicy`/`ClientTrafficPolicy`/`BackendTrafficPolicy`, Mutating/Validating webhook-конфигурации (секрет `aibrix-webhook-server-cert` заполняется встроенным cert-rotator'ом — **cert-manager не нужен**).

### 2.2. Namespace `envoy-gateway-system`

Envoy Gateway v1.2.8 (контроллер) + дата-плейн поды `envoy-aibrix-system-aibrix-eg-<hash>` (Envoy v1.33.2), создаваемые при reconcile объекта Gateway. **Envoy Gateway — жёсткая зависимость**: «AIBrix requires Envoy Gateway for request routing» ([installation docs](https://aibrix.readthedocs.io/latest/getting_started/installation/installation.html)). Gateway API CRD'ки устанавливаются вместе с Envoy Gateway.

### 2.3. Дата-плейн в namespace'ах моделей (не в aibrix-system)

| Компонент | Что делает | Обязателен? |
|---|---|---|
| Поды движков (vLLM/SGLang/TensorRT-LLM) | Инференс; метки `model.aibrix.ai/name`, `model.aibrix.ai/port`, `model.aibrix.ai/engine` | Да |
| Сайдкар `aibrix-runtime:v0.7.0` (:8080) | Стандартизация метрик, скачивание артефактов (s3/gcs/приватный HF), инжектится webhook'ом или вручную | Опционален (рекомендуется для LoRA) |
| Semantic router (ext_proc из `samples/semantic-router/`) | Классификация промптов и перезапись поля `model` | Отдельная опция, не входит в дефолт |

### 2.4. Чего в кластере НЕ будет (v0.7.0)

- **Нет Jaeger, нет OpenTelemetry Collector, нет Prometheus.** Проверено по всем трём манифестам релиза. Трейсинг — opt-in через ваш OTLP-endpoint; мониторинг — ваш kube-prometheus-stack. (Jaeger/otel-collector были в standalone-чарте эпохи v0.1.x по адресу `aibrix.github.io/helm-charts` — тот хост сегодня мёртв (404); актуальный чарт — `dist/chart`.)
- Консоль (UI) — отдельная опция, зрелость preview, по умолчанию не ставится.
- Старые поды `aibrix-orchestrator`/`aibrix-gateway` (до v0.2.x) — заменены на Envoy Gateway + `aibrix-gateway-plugins`.

## 3. CRD (все `v1alpha1`)

| Kind | apiVersion | Назначение |
|---|---|---|
| `PodAutoscaler` | `autoscaling.aibrix.ai` | LLM-автоскейлинг (HPA/KPA/APA), метрики вплоть до утилизации KV-cache. Цель — одноимённый Deployment |
| `ModelAdapter` | `model.aibrix.ai` | Жизненный цикл LoRA-адаптера: скачать `artifactURL`, загрузить в поды, создать Service/EndpointSlice. Фазы Pending→Scheduled→Loading→Bound→Running |
| `StormService` | `orchestration.aibrix.ai` | Верхнеуровневая оркестрация (3 слоя: StormService→RoleSet→PodSet): TP/PP/single-GPU и P/D-дисагрегация **без Ray** |
| `RoleSet` | `orchestration.aibrix.ai` | Набор ролей (prefill/decode) внутри StormService |
| `PodSet` | `orchestration.aibrix.ai` | Группа подов, работающих согласованно (gang-группировка) |
| `KVCache` | `orchestration.aibrix.ai` | L2 распределённый KV-cache-сервер (consistent hashing) |
| `RayClusterFleet` / `RayClusterReplicaSet` | `orchestration.aibrix.ai` | API над Ray-кластерами для мульти-нодового инференса; требует KubeRay |

## 4. Карта фич → инфраструктура → работает ли без RDMA

Коды требований: **CPU** — обычные ноды, обычная сеть · **1×GPU** — одна GPU-нода, обычная сеть · **RDMA-класс** — мульти-нодовый быстрый интерконнект как документированный путь производительности.

| Фича | Суть | Требование | Без RDMA? |
|---|---|---|---|
| LLM-шлюз и маршрутизация | 19 алгоритмов: `random`, `least-request`, `least-busy-time`, `least-latency`, `least-kv-cache`, `least-gpu-cache`, `least-utilization`, `throughput`, `power-of-two`, `prefix-cache`, `prefix-cache-preble`, `vtc-basic`, SLO-группа, `pd`, `session-affinity`; блендинг стратегий | CPU | ✅ да (чистый L7) |
| Session affinity | Sticky-роутинг по `x-session-id` | CPU | ✅ да |
| Semantic router | Классификация промптов, перезапись `model` | CPU (+GPU для моделей) | ✅ да (опция) |
| Учёт токенов / rate limiting | RPM/TPM на пользователя, лимиты RPS на модель | CPU + Redis | ✅ да |
| Наблюдаемость | Стандартизация метрик vLLM/SGLang/TRT-LLM, дашборды TTFT/TPOT, opt-in трейсинг | CPU (+свой prometheus-stack) | ✅ да |
| Inference-shaped autoscaling | PodAutoscaler: HPA/KPA/APA; метрики KV-cache | CPU | ✅ да (см. [docs/03](03-autoscaling.md)) |
| LoRA dynamic loading | ModelAdapter, плотность адаптеров на под | 1×GPU | ✅ да (см. [docs/04](04-lora-dynamic-loading.md)) |
| Реестр моделей / Batch API | Metadata-service, JSONL-батчи через K8s Jobs | CPU (+GPU для исполнения) | ✅ да |
| Мульти-движки | vLLM, SGLang, TensorRT-LLM за одним шлюзом (лейбл `model.aibrix.ai/engine`) | 1×GPU | ✅ да |
| Гетерогенные GPU | Одна модель на разных типах GPU (экспериментально) | 1×GPU каждого типа | ✅ да |
| Runtime-сайдкар | Метрики, скачивание моделей, абстракция движка | 1×GPU | ✅ да |
| KV-cache offloading **L1** | DRAM-кэш в памяти пода (S3FIFO/LRU/FIFO) — разгрузка GPU-памяти | 1×GPU + host RAM | ✅ да — документированный «простой» путь |
| KV event sync | ZMQ pub/sub событий KV-cache из vLLM в шлюз (лучший prefix-cache роутинг) | 1×GPU, обычный TCP | ✅ да |
| GPU failure detection | «Accelerator Diagnose Tools» | GPU | ✅ да (документация обзорная) |
| KV-cache offloading **L2** / cross-engine reuse | InfiniStore (дефолт подключения — **RDMA**), PrisKV, HPKV, EIC | мульти-нод, RDMA-ориентированно | ❌ фактически нет |
| PD-дисагрегация | Роутинг prefill/decode работает где угодно, но **трансфер KV** между нодами — NIXL/UCX с RDMA | роутинг CPU; трансфер — интерконнект | ⚠️ частично (см. ниже) |
| Распределённый (мульти-нодовый) инференс | RayClusterFleet/RayClusterReplicaSet, TP/PP между нодами | мульти-нод GPU | ⚠️ вне рамок (наш кластер без RDMA) |

**Итог по «что работает без RDMA»:**

- ✅ **Работает полностью (документировано):** шлюз со всеми routing-алгоритмами (кроме KV-трансфера у `pd`), session affinity, semantic router, rate limiting и учёт токенов, наблюдаемость, все режимы автоскейлинга, LoRA dynamic loading, реестр моделей и Batch API, мульти-движки, гетерогенные GPU, KV L1 offloading, KV event sync, runtime-сайдкар.
- ❌ **Не для нашего кластера:** Ray-мульти-нодовый инференс (пропускаем установку KubeRay — контроллер сам деактивируется), L2 cross-engine KV reuse с InfiniStore (RDMA-дефолт), кросс-нодовый KV-трансфер при P/D (NIXL/UCX RDMA-сборки).
- ⚠️ **Серая зона:** PD-дисагрегация внутри одной ноды — документированная топология (пары ролей в одном RoleSet), но сетевой транспорт NIXL для same-node пар явно не документирован — если понадобится, сначала PoC (готовый манифест и разбор — [docs/05, Сценарий 8](05-usage-scenarios.md)).

## 5. Зачем разворачивать AIBrix без RDMA (обоснование)

Весь контроль-плейн AIBrix — CPU-only и компактный (реквесты по умолчанию из чарта):

| Компонент | requests | limits |
|---|---|---|
| controller-manager | 10m / 64Mi | 500m / 128Mi |
| gateway-plugins | 1 CPU / 1Gi | 1 CPU / 1Gi |
| metadata-service | 50m / 128Mi | 500m / 512Mi |
| gpu-optimizer | 10m / 64Mi | 500m / 256Mi |
| redis | 100m / 100Mi | — |
| envoy (дата-плейн) | 1 CPU / 1Gi | 1 CPU / 1Gi |

≈ **2.5 vCPU / 2.5 GiB** накладных расходов (плюс Envoy Gateway-контроллер) — и вы получаете:

1. **LLM-aware шлюз** с 19 алгоритмами маршрутизации, session affinity и rate limiting — то, чего нет ни у обычного NGINX/Envoy, ни у Kubeflow Serving;
2. **Inference-shaped автоскейлинг** (KPA/APA) по метрикам инференса — num_requests_waiting, gpu_cache_usage_perc и т.д. — вместо CPU-метрик, бессмысленных для LLM (см. [docs/03](03-autoscaling.md));
3. **Динамическую загрузку LoRA** — десятки адаптеров на одном пуле GPU без пересоздания под (см. [docs/04](04-lora-dynamic-loading.md));
4. **KV L1 offloading** — экономию GPU-памяти уже на одиночных нодах;
5. Опционально — semantic router, гетерогенные GPU, Batch API.

Всё это — ровно те сценарии одного/нескольких GPU-нод без быстрого интерконнекта, которые и нужны большинству сервисов, пока не наступает эпоха распределённого инференса.

## 6. Требования к Kubernetes

- Явного минимума версий AIBrix **не документирует**. Проверяемые ориентиры: собран против `k8s.io v0.31.8` / controller-runtime 0.19.2; CI гоняет на kind v0.24.0; жёсткая зависимость **Envoy Gateway v1.2.x официально поддерживает Kubernetes 1.28–1.31+** ([матрица](https://gateway.envoyproxy.io/news/releases/matrix/)).
- **Практический минимум: K8s ≥ 1.28.** Selectel MKS предлагает 1.34–1.36 — полностью покрывает (см. [docs/06](06-selectel-mks-notes.md)).
- Документация: «AIBrix installation does not rely on other cloud specific features. It's fully compatible with vanilla Kubernetes» — облачно-специфичных фич не требуется.

## Источники

- Репозиторий: https://github.com/vllm-project/aibrix · Релиз: https://github.com/vllm-project/aibrix/releases/tag/v0.7.0
- Документация: [installation](https://aibrix.readthedocs.io/latest/getting_started/installation/installation.html) · [architecture](https://aibrix.readthedocs.io/latest/designs/architecture.html) · [gateway plugins](https://aibrix.readthedocs.io/latest/features/gateway-plugins.html) · [kvcache offloading](https://aibrix.readthedocs.io/latest/features/kvcache-offloading.html) · [KV framework](https://aibrix.readthedocs.io/latest/designs/aibrix-kvcache-offloading-framework.html) · [PD](https://aibrix.readthedocs.io/latest/features/pd-disaggregation.html) · [container images](https://aibrix.readthedocs.io/latest/getting_started/container-images.html) · [observability](https://aibrix.readthedocs.io/latest/production/observability.html)
- ai-on-eks: [aibrix-core ArgoCD app](https://github.com/awslabs/ai-on-eks/blob/main/infra/base/terraform/argocd-addons/aibrix-core.yaml) · [страница AIBrix on EKS](https://awslabs.github.io/ai-on-eks/docs/infra/inference/aibrix)
- Матрица совместимости Envoy Gateway: https://gateway.envoyproxy.io/news/releases/matrix/
