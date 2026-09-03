# 03 — Автоскейлинг: AIBrix inference-shaped autoscaling × Selectel MKS

> **Вердикт: РАБОТАЕТ С ОГОВОРКАМИ (статус: проверено по документации обеих систем).**
>
> `PodAutoscaler` AIBrix (стратегии **KPA/APA** на LLM-метриках) корректно компонуется с Cluster Autoscaler (CA) Selectel MKS на GPU-нодгруппах — это стандартный паттерн «pod-автоскейлер → Pending-поды → масштабирование нод», описанный в документации обеих сторон ([FAQ Cluster Autoscaler](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md), [документация Selectel](https://docs.selectel.ru/en/managed-kubernetes/node-groups/autoscaling/)).
>
> Оговорки:
> 1. GPU-нодгруппы **обязаны использовать предустановленные драйверы Selectel** — с самостоятельной установкой через GPU Operator автоскейлинг нод недоступен.
> 2. Стратегия **HPA** с LLM-метриками требует custom-metrics-адаптер, которого нет ни в AIBrix, ни в MKS — **используйте KPA/APA**.
> 3. Сквозная задержка масштабирования определяется провижинингом нод и загрузкой модели, а не скоростью AIBrix.
> 4. Scale-down может обрывать in-flight стриминговые запросы, если не настроены PDB и drain-режим vLLM.
>
> **Версия:** разворачиваем AIBrix **v0.7.0**; таблица аннотаций и сэмплы ниже сверены с этим релизом. Ссылки на Go-код указывают на main-коммит `991fb82` (сразу после v0.7.0) — как ближайшую проверенную точку исходников.

---

## Часть 1. Как работает inference-shaped autoscaling в AIBrix

### 1.1. Компонент и CRD

AIBrix предоставляет CRD **`PodAutoscaler`** (apiVersion `autoscaling.aibrix.ai/v1alpha1`) с несколькими алгоритмами ([документация](https://aibrix.readthedocs.io/latest/features/autoscaling/autoscaling.html)).

Реализация — контроллер **`pod-autoscaler-controller` внутри `aibrix-controller-manager`** (namespace `aibrix-system`). Пакет контроллера документирует три стратегии и модель делегирования ([podautoscaler_controller.go @ `991fb82`](https://github.com/vllm-project/aibrix/blob/991fb82c1a48c52e5c1fb492f5806218880cbef8/pkg/controller/podautoscaler/podautoscaler_controller.go)):

```go
// Package podautoscaler provides controllers for managing PodAutoscaler resources.
// The controller supports three scaling strategies:
// - HPA: Creates and manages Kubernetes HorizontalPodAutoscaler resources (KEDA-like wrapper)
// - KPA: Knative-style Pod Autoscaling with panic/stable windows
// - APA: Application-specific Pod Autoscaling with custom metrics
```

Документация подтверждает размещение: *«Pod autoscaler is part of aibrix controller manager which plays the role of collecting the metrics from each pod»* — логи: `kubectl logs <aibrix-controller-manager-podname> -n aibrix-system`. Доступна и standalone-установка только автоскейлера: `kubectl apply -k config/standalone/autoscaler-controller/` ([Installation](https://aibrix.readthedocs.io/latest/getting_started/installation/installation.html)).

### 1.2. Процесс масштабирования (по документации)

1. Создаёте `PodAutoscaler`, указывающий на workload через `scaleTargetRef` — `Deployment`, роль `StormService` или `RayClusterFleet`.
2. Контроллер собирает метрику из `metricsSources`:
   - `metricSourceType: pod` — скрейпит **каждый под** целевого deployment по HTTP (`/metrics`; `/prometheus/metrics` для `trtllm`);
   - `metricSourceType: external` — читает один HTTP-endpoint (так GPU optimizer отдаёт рекомендацию); если `endpoint` пуст — используется Kubernetes `external.metrics` API.
3. Выбранный алгоритм (HPA/KPA/APA) превращает наблюдаемое значение + `targetValue` в желаемое число реплик (окна `observeWindowSeconds` / `panicWindowSeconds`).
4. Результат ограничивается `minReplicas`/`maxReplicas` (или активными `schedules`) и **напрямую записывается в replica count цели**.

Это **горизонтальное per-model масштабирование** — один `PodAutoscaler` на Deployment модели, по LLM-метрикам вместо CPU.

### 1.3. Метрики (engine-neutral имена)

`targetMetric` использует абстрактное имя AIBrix, которое контроллер транслирует в экспорт конкретного движка ([Multi-Engine Support](https://aibrix.readthedocs.io/latest/features/multi-engine.html)). Ключевые метрики:

| Метрика AIBrix | Экспорт vLLM | Смысл для масштабирования |
|---|---|---|
| `num_requests_running` | `vllm:num_requests_running` | запросы в обработке |
| `num_requests_waiting` | `vllm:num_requests_waiting` | **глубина очереди** |
| `gpu_cache_usage_perc` | `vllm:gpu_cache_usage_perc` | утилизация KV-cache/GPU |
| `kv_cache_usage_perc` | `vllm:kv_cache_usage_perc` | утилизация KV-cache |
| `time_to_first_token_seconds` | `vllm:time_to_first_token_seconds` | TTFT |
| `e2e_request_latency_seconds` | `vllm:e2e_request_latency_seconds` | сквозная задержка |
| `avg_generation_throughput_toks_per_s` | `vllm:avg_generation_throughput_toks_per_s` | генерация, токенов/с |
| `request_queue_time_seconds` | `vllm:request_queue_time_seconds` | время в очереди |

Поды обнаруживаются по лейблу `model.aibrix.ai/name`; движок — `model.aibrix.ai/engine` (по умолчанию `vllm`); порт метрик — `model.aibrix.ai/metric-port` (по умолчанию `8000`).

### 1.4. Стратегии и отличия от ванильного HPA

| Стратегия | Алгоритм | Документированный сценарий |
|---|---|---|
| **HPA** | Тот же алгоритм, что у K8s HPA; контроллер **генерирует нативный HorizontalPodAutoscaler** (`<name>-hpa`) | Ровный трафик, привычное поведение |
| **KPA** | Стиль Knative: два окна — длинное `stable` + короткое `panic`; быстрый scale-up при пересечении panic-порога. Метрики собираются **внутри AIBrix, без Prometheus** | Взрывной трафик, где важна скорость реакции |
| **APA** | Собственный алгоритм AIBrix: **допуск на флуктуации** (up/down-fluctuation-tolerance), который надо превысить для масштабирования — подавляет осцилляции | Сервисы, чувствительные к латентности, которым нельзя «дёргаться» |
| **Optimizer-based** | Не значение стратегии: GPU optimizer считает реплики из офлайн-бенчмарков + SLO и отдаёт метрику `vllm:deployment_replicas`, которую потребляет KPA-PodAutoscaler через external-источник | SLO/cost-driven, гетерогенные GPU |

Ключевые отличия от ванильного HPA (всё документировано):
- **LLM-нативные метрики** (глубина очереди, утилизация KV-cache, TTFT, токены/с) вместо CPU;
- **multi-metric autoscaling**: несколько `metricsSources`, итог = максимум по всем метрикам;
- **расписания min/max** (`spec.schedules`, IANA timezone, дни недели);
- **panic mode** (KPA) и **tolerance** (APA) для реакции на всплески и подавления осцилляций;
- аннотация **`scale-to-zero`** (KPA/APA, ограничена `minReplicas`).

### 1.5. Примеры манифестов (из документации/сэмплов AIBrix)

**KPA по утилизации KV-cache** ([samples/autoscaling/kpa.yaml @ v0.7.0](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/autoscaling/kpa.yaml); таблица аннотаций — [доки v0.7.0](https://github.com/vllm-project/aibrix/blob/v0.7.0/docs/source/features/autoscaling/metric-based-autoscaling.rst)):

> Сноска: в самом файле сэмпла на теге v0.7.0 осталась устаревшая аннотация `kpa.autoscaling.aibrix.ai/scale-down-delay`; актуальное документированное имя (в таблице аннотаций релиза) — `autoscaling.aibrix.ai/scale-down-cooldown-window`, как в примере ниже. Наш манифест `manifests/podautoscaler-kpa.yaml` использует документированное имя.

```yaml
apiVersion: autoscaling.aibrix.ai/v1alpha1
kind: PodAutoscaler
metadata:
  name: deepseek-r1-distill-llama-8b-kpa
  namespace: default
  annotations:
    autoscaling.aibrix.ai/scale-down-cooldown-window: 3m
spec:
  scalingStrategy: KPA
  minReplicas: 1
  maxReplicas: 8
  metricsSources:
    - metricSourceType: pod
      protocolType: http
      port: '8000'
      path: metrics
      targetMetric: gpu_cache_usage_perc
      targetValue: '0.5'
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: deepseek-r1-distill-llama-8b
```

**Мульти-метрика APA (KV-cache + глубина очереди)** ([Metric-based Autoscaling → Multi-Metric](https://aibrix.readthedocs.io/latest/features/autoscaling/metric-based-autoscaling.html)):

```yaml
spec:
  scalingStrategy: APA
  minReplicas: 1
  maxReplicas: 3
  metricsSources:
    - metricSourceType: pod
      protocolType: http
      port: '8000'
      path: metrics
      targetMetric: gpu_cache_usage_perc
      targetValue: '0.5'
    - metricSourceType: pod
      protocolType: http
      port: '8000'
      path: metrics
      targetMetric: num_requests_waiting
      targetValue: '100'
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: mock-llama2-7b
```

**Optimizer-based KPA** ([samples/autoscaling/optimizer-kpa.yaml @ v0.7.0](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/autoscaling/optimizer-kpa.yaml)):

```yaml
spec:
  scalingStrategy: KPA
  minReplicas: 1
  maxReplicas: 8
  metricsSources:
  - endpoint: aibrix-gpu-optimizer.aibrix-system.svc.cluster.local:8080
    metricSourceType: external
    path: /metrics/default/deepseek-r1-distill-llama-8b
    protocolType: http
    targetMetric: vllm:deployment_replicas
    targetValue: "100"
```

Целевой Deployment несёт лейблы `model.aibrix.ai/name` + `model.aibrix.ai/port`, запросы `nvidia.com/gpu: 1` и **probes с `initialDelaySeconds: 120`** (важно для cold start — см. §3.3): [samples/autoscaling/deploy.yaml @ v0.7.0](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/autoscaling/deploy.yaml). Имя в `scaleTargetRef` должно точно совпадать с именем workload.

### 1.6. Поведение масштабирования: окна, скорости, стабилизация (дефолты)

| Параметр | Дефолт | Применимость |
|---|---|---|
| `observeWindowSeconds` | 180 (диапазон 1–3600) | все — стабильное окно |
| `panicWindowSeconds` | 60 (диапазон 1–3600, ≤ observe) | KPA — panic-окно |
| `autoscaling.aibrix.ai/max-scale-up-rate` | 2 | HPA, KPA, APA |
| `autoscaling.aibrix.ai/max-scale-down-rate` | 2 | HPA, KPA, APA |
| `autoscaling.aibrix.ai/scale-up-tolerance` / `scale-down-tolerance` | 0.1 | KPA, APA |
| `autoscaling.aibrix.ai/panic-threshold` | 2.0 | KPA |
| `autoscaling.aibrix.ai/scale-up-cooldown-window` | 0s | HPA, KPA, APA |
| `autoscaling.aibrix.ai/scale-down-cooldown-window` | **300s** | HPA, KPA, APA |
| `autoscaling.aibrix.ai/scale-to-zero` | false | KPA, APA |
| APA `up/down-fluctuation-tolerance`, `apa.autoscaling.aibrix.ai/window` | 0.1 / 0.2 / 30s (примеры) | APA |

Источник: [таблица аннотаций](https://aibrix.readthedocs.io/latest/features/autoscaling/metric-based-autoscaling.html). Выводы самих разработчиков из экспериментов: *HPA — самая высокая задержка из-за медленной реакции; KPA — самая реактивная благодаря panic mode; APA экономит ресурсы, но может превысить латентность при агрессивном scale-down*.

### 1.7. Требования AIBrix внутри кластера

- **Для `pod`-источника метрик (KPA/APA) не нужны ни metrics-server, ни Prometheus** — *«AIBrix fetches and maintains metrics internally, enabling faster response times»*.
- **Стратегия HPA**: контроллер генерирует **нативный HPA**. Для `cpu`/`memory` — `Resource` metric source; для любой другой метрики — **`Pods` metric source** с сырым именем метрики ([hpa_resources.go @ `991fb82`](https://github.com/vllm-project/aibrix/blob/991fb82c1a48c52e5c1fb492f5806218880cbef8/pkg/controller/podautoscaler/hpa_resources.go)). Нативный HPA резолвит `Pods`-метрики через custom-metrics API — **AIBrix не поставляет custom-metrics APIService** (проверено: в репозитории на коммите `991fb82` его нет), значит для LLM-метрик через HPA-стратегию нужен сторонний адаптер (например, Prometheus Adapter). Статус: код-путь проверен; требование адаптера — стандартное поведение K8s HPA.
- **`external` без endpoint** (K8s `external.metrics.k8s.io`): требует external-metrics-адаптер; RBAC AIBrix уже даёт `get`/`list` на эту API-группу.
- **Базовая установка**: полностью совместима с vanilla Kubernetes; для маршрутизации нужен Envoy Gateway; KubeRay опционален (только для распределённого инференса). Дефолтная установка включает GPU optimizer и Redis (`aibrix-redis-master` в `aibrix-system`). Optimizer-based режим дополнительно требует включённого трейсинга на gateway-плагине (`AIBRIX_GPU_OPTIMIZER_TRACING_FLAG=true`, по умолчанию выключен) и офлайн-профилирование (`pip3 install aibrix`).

---

## Часть 2. Автоскейлинг нод в Selectel MKS

Все факты — из официальной документации Selectel ([docs.selectel.ru](https://docs.selectel.ru/en/managed-kubernetes/node-groups/autoscaling/)).

### 2.1. Тип автоскейлера и принцип работы

- Два инструмента: **Cluster Autoscaler** (устанавливается автоматически при создании кластера; включается на нодгруппе) и **Karpenter** (самостоятельная установка через Helm-чарт `oci://ghcr.io/selectel/mks-charts/karpenter`). Одновременно использовать нельзя.
- CA работает с **существующими нодгруппами и предвыбранными конфигурациями**: каждые **10 секунд** проверяет поды в статусе `PENDING` и анализирует **запросы vCPU, RAM и GPU**.
- **Scale-up**: Pending-поды → добавление нод в пределах min/max нодгруппы (панель / [API](https://docs.selectel.ru/en/api/managed-kubernetes/) / Terraform `enable_autoscale`, `autoscale_min_nodes`, `autoscale_max_nodes`). K8s ≥1.28 — несколько групп масштабируются одновременно и равномерно; ≤1.27 — одна нода за цикл.
- **Scale-down**: нет Pending-подов → если запрошенные ресурсы ноды < **50%** (дефолт) → нода помечается ненужной; если так **10 минут** → проверка возможности выселения подов → удаление по одной за цикл. CA **не будет** выселять поды при: рестриктивном PodDisruptionBudget, kube-system-подах без PDB, подах без контроллера, local storage, отсутствии места на других нодах, несовпадении nodeSelector/affinity. Аннотация: `cluster-autoscaler.kubernetes.io/safe-to-evict: "true"`.
- **Scale-to-zero**: на нодгруппу, если в других группах остаётся ≥2 рабочих ноды.

### 2.2. Настраиваемые параметры CA (per-nodegroup)

Через ConfigMap `cluster-autoscaler-nodegroup-options` в `kube-system` (ключи — UUID нодгрупп):

| Параметр | Дефолт | Значение |
|---|---|---|
| `scaleDownUtilizationThreshold` | 0.5 | порог загрузки vCPU+RAM для удаления ноды |
| `scaleDownGpuUtilizationThreshold` | 0.5 | порог загрузки **GPU** для удаления ноды |
| `scaleDownUnneededTime` | 10m | ожидание перед удалением малонагруженной ноды |
| `scaleDownUnreadyTime` | 20m | ожидание перед удалением NotReady-ноды |
| `maxNodeProvisionTime` | 15m | таймаут добавления ноды; по истечении процесс перезапускается |
| `zeroOrMaxNodeScaling` | false | группа масштабируется только в 0 или в max (всё сразу) |
| `ignoreDaemonSetsUtilization` | false | игнорировать DaemonSet'ы при решении о scale-down |

Рекомендации Selectel: проверить, что **квоты** (vCPU/RAM/GPU) покрывают максимум нод; указывать **resource requests** в манифестах; настроить **PodDisruptionBudget**; не менять размер нод вручную; держать ноды в группе одинаковыми.

### 2.3. GPU-нодгруппы

- GPU-ноды — **фиксированные конфигурации** линейки GL, 1–8 GPU на ноду ([конфигурации](https://docs.selectel.ru/en/managed-kubernetes/node-groups/configurations/), [создание GPU-кластера](https://docs.selectel.ru/en/managed-kubernetes/create/create-cloud-gpu-cluster/)).
- **Драйверы**: по умолчанию тумблер GPU Drivers включён → **предустановленные драйверы + NVIDIA device plugin** (в API — `install_nvidia_device_plugin`). Если выключить и ставить самому через **NVIDIA GPU Operator**: *«For GPU node groups without drivers, cluster autoscaling is unavailable»*. То есть **GPU-нодгруппы с предустановленными драйверами масштабируются**, ограничение касается только режима без драйверов (и dedicated-серверов).
- **Доступные GPU**: A100 40/80 GB, H100, H200, L4, RTX 6000 Ada (аналог L40), RTX 6000 Pro, RTX 4090 24/48, T4, A30, A2, A2000, A5000 и др. Доступность зависит от пула/сегмента ([матрица](https://docs.selectel.ru/en/infrastructure/availability-matrix/)): H100 — ru-7b; H200 — ru-6a/6b/6c, ru-7b; A100 40 — ru-7a, ru-9a (СПб); L4 — ru-6a, ru-7a.
- **Metrics Server** предустановлен в MKS ≥1.27 (обслуживает HPA/VPA через Metrics API) — [страница](https://docs.selectel.ru/en/managed-kubernetes/clusters/metrics-server/).
- **Karpenter-альтернатива**: требует K8s ≥1.28, отключённых автоскейлинга и auto-healing, ≥1 ноды 2 vCPU/4 GiB; GPU-селекторы вида `karpenter.k8s.selectel/instance-gpu-name: ["A100","H100"]`. Та же модель триггера (Pending-поды).

---

## Часть 3. Совместимость

### 3.1. Почему компонуется (документированное поведение обеих сторон)

```
трафик ↑ → поды vLLM отдают num_requests_waiting / gpu_cache_usage_perc на /metrics
        → AIBrix pod-autoscaler-controller (KPA/APA) считает желаемые реплики
        → Deployment replicas ↑ → новые поды запрашивают nvidia.com/gpu → Pending
        → Cluster Autoscaler Selectel (скан 10 с) видит Pending-поды + GPU-запросы
        → нода добавляется в пределах min/max группы (GPU-конфиг, предустановленные драйверы)
        → под vLLM планируется → pull образа → загрузка модели → readiness → трафик
```

Это канонический паттерн HPA↔CA из upstream-FAQ — *«If there are not enough resources, CA will try to bring up some nodes, so that the HPA-created pods have a place to run»* — где роль драйвера реплик вместо HPA выполняет PodAutoscaler. Документация Selectel прямо говорит, что CA анализирует *«requests from pods for vCPU, RAM, and GPU»*, так что запросы `nvidia.com/gpu` — первоклассный сигнал scale-up. Конфликтов нет: AIBrix не требует кластерных прав сверх своих CRD/RBAC, Selectel не ограничивает установку операторов.

**Выбор стратегии:**
- **KPA / APA — чистое совпадение.** Метрики скрейпятся контроллером AIBrix с каждого пода напрямую; нет зависимости от metrics-server, Prometheus и metrics API. Работает на любом конформном Kubernetes.
- **HPA-стратегия — частично.** С `cpu`/`memory` — работает (Resource metrics API; Metrics Server в MKS есть по умолчанию). С LLM-метрикой (например `gpu_cache_usage_perc`) генерируется `Pods` metric source → нужен **custom-metrics-адаптер, которого нет ни в AIBrix, ни в Selectel**. Рекомендация: для LLM-метрик — KPA/APA.
- **Optimizer-based — совместимо**, но больше движущихся частей (Redis, трейсинг, профилирование). Результат всё равно идёт через PodAutoscaler → Deployment → тот же путь CA.

### 3.2. Оговорки (явный список)

1. **Драйверы GPU — жёсткое условие.** Только предустановленные драйверы Selectel; с GPU Operator кластерный автоскейлинг на таких группах недоступен.
2. **Задержка scale-up определяется нодами, а не AIBrix.** По FAQ CA: общее время = время реакции pod-автоскейлера + реакция CA + **провижининг ноды**. AIBrix KPA реагирует за секунды; доминируют провижининг ноды (таймаут `maxNodeProvisionTime` 15 м; фактическая латентность **не документирована**) и загрузка модели (сэмпл AIBrix ставит `initialDelaySeconds: 120`). Для взрывного трафика: `zeroOrMaxNodeScaling: true` или тёплый `minReplicas`/минимум нодгруппы.
3. **Scale-down медленный на обоих уровнях — настраивайте осознанно.** AIBrix: `scale-down-cooldown-window: 300s`, `max-scale-down-rate: 2`. CA: порог 0.5 (включая `scaleDownGpuUtilizationThreshold`), `scaleDownUnneededTime: 10m`. Scale-down подов может опережать удаление нод на >10 минут; всплеск трафика в этом окне повторно запускает провижининг (риск flapping). Митигации (документированы): поднять cooldown-ы AIBrix, поднять `scaleDownUnneededTime`/GPU-порог через ConfigMap, либо `zeroOrMaxNodeScaling: true` для GPU-групп «всё или ничего».
4. **PDB защищает стримы, но блокирует удаление нод.** Selectel рекомендует PodDisruptionBudget; FAQ CA прямо называет рестриктивный PDB блокатором scale-down. PDB с `maxUnavailable: 0` фактически «прибинтует» GPU-ноды (что может быть именно нужно для долгих SSE-стримов).
5. **Обрыв in-flight стримов при выселении — зависит от версии vLLM.** Исторически SIGTERM обрывал in-flight запросы; graceful drain-режим (`--shutdown-timeout`, 503 для новых при догрузке старых) появился в vLLM через PR [#32420](https://github.com/vllm-project/vllm/pull/32420), [#34730](https://github.com/vllm-project/vllm/pull/34730), [#36666](https://github.com/vllm-project/vllm/pull/36666). Ставьте `terminationGracePeriodSeconds` больше худшего времени генерации и проверьте поддержку drain в конкретном образе vLLM. Статус: **проверьте вашу версию vLLM — универсально не подтверждено**.
6. **Квоты.** Квоты проекта (vCPU/RAM/GPU) должны покрывать максимум нод автомасштабируемых групп, иначе scale-up молча упрётся в квоту.
7. **Scale-to-zero (оба уровня) дорог для LLM.** Ноль нодгруппы требует ≥2 рабочих нод в других группах; `scale-to-zero` AIBrix ограничен `minReplicas`; GPU optimizer советует держать ≥1 реплику (`model.aibrix.ai/min_replicas`). Событие 0→1 = провижининг ноды + pull + загрузка модели.
8. **Только один нод-автоскейлер.** Не запускайте CA и Karpenter одновременно (Karpenter требует отключённых автоскейлинга и auto-healing).
9. **HPA-стратегия + LLM-метрика требует адаптер** (см. §3.1) — в MKS по умолчанию его нет.

### 3.3. Бюджет холодного старта GPU (документированные составляющие)

- Скан CA: **10 с**.
- Провижининг ноды: таймаут **15 м** (дефолт); реальная латентность не публикуется (*не подтверждено*).
- Pull образа контейнера: зависит от registry (числом не документировано).
- Загрузка модели: сэмпл AIBrix — `initialDelaySeconds: 120` на readiness для 8B-модели; для больших моделей — больше.
- Вывод: для критичных к латентности всплесков держите буфер (`minReplicas` выше, тёплый минимум нодгруппы, `zeroOrMaxNodeScaling`).

### 3.4. Что **не подтверждено** (по официальным докам)

- Фактическая длительность провижининга нод Selectel (документирован только таймаут 15 м).
- Конкретная версия/флаги Cluster Autoscaler, которые использует Selectel (документированы только параметры ConfigMap).
- Поведение graceful shutdown в конкретной развёрнутой версии vLLM (фича в процессе стабилизации — проверяйте по релизу).
- Внутреннее поведение CA Selectel за пределами опубликованных параметров.

---

## Источники

**AIBrix (доки + репозиторий @ `991fb82c1a48c52e5c1fb492f5806218880cbef8`, main на 2026-09-01):**
- [Autoscaling (обзор)](https://aibrix.readthedocs.io/latest/features/autoscaling/autoscaling.html) · [Metric-based Autoscaling](https://aibrix.readthedocs.io/latest/features/autoscaling/metric-based-autoscaling.html) · [Optimizer-based Autoscaler](https://aibrix.readthedocs.io/latest/features/autoscaling/optimizer-based-autoscaling.html) · [Multi-Engine Support](https://aibrix.readthedocs.io/latest/features/multi-engine.html) · [Installation](https://aibrix.readthedocs.io/latest/getting_started/installation/installation.html) · [Дизайн автоскейлера](https://aibrix.readthedocs.io/latest/designs/aibrix-autoscaler.html)
- [podautoscaler_controller.go](https://github.com/vllm-project/aibrix/blob/991fb82c1a48c52e5c1fb492f5806218880cbef8/pkg/controller/podautoscaler/podautoscaler_controller.go) · [hpa_resources.go](https://github.com/vllm-project/aibrix/blob/991fb82c1a48c52e5c1fb492f5806218880cbef8/pkg/controller/podautoscaler/hpa_resources.go) · [samples/autoscaling/](https://github.com/vllm-project/aibrix/tree/main/samples/autoscaling)

**Selectel (официальные доки):**
- [Автоскейлинг в MKS](https://docs.selectel.ru/en/managed-kubernetes/node-groups/autoscaling/) · [Metrics Server](https://docs.selectel.ru/en/managed-kubernetes/clusters/metrics-server/) · [Драйверы GPU](https://docs.selectel.ru/en/managed-kubernetes/node-groups/gpu-drivers/) · [GPU-кластер](https://docs.selectel.ru/en/managed-kubernetes/create/create-cloud-gpu-cluster/) · [Конфигурации нод](https://docs.selectel.ru/en/managed-kubernetes/node-groups/configurations/) · [Матрица доступности](https://docs.selectel.ru/en/infrastructure/availability-matrix/) · [Terraform mks_nodegroup_v1](https://docs.selectel.ru/en/terraform/selectel-provider-reference/resources/mks_nodegroup_v1/) · [MKS API](https://docs.selectel.ru/en/api/managed-kubernetes/)

**Экосистема Kubernetes:**
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md) (HPA+CA, PDB-блокеры, скорость) · [PodDisruptionBudgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/) · vLLM shutdown: PR [#32420](https://github.com/vllm-project/vllm/pull/32420), [#34730](https://github.com/vllm-project/vllm/pull/34730), [#36666](https://github.com/vllm-project/vllm/pull/36666)

---

> **Факты vs предположения:** все механизмы AIBrix в §1 — из документации AIBrix или пиннед-коммита репозитория; все утверждения о Selectel в §2 — из docs.selectel.ru. Вердикт совместимости в §3 выведен только из документированного паттерна HPA+CA и документированных ограничений; непроверяемое явно помечено «не подтверждено».
