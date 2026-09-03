# Чеклист задачи — AIBrix на Selectel MKS

Исходный список (✅ = готово, с указанием где):

## Базовые пункты

- [x] **Изучить AIBrix, понять какие компоненты входят в aibrix-system** (controller-manager, orchestrator/gateway-controller, redis, jaeger, opentelemetry-collector, monitor/metrics), для чего нужны
  → `docs/01-aibrix-overview.md` §2–3.
  Актуальная картина v0.7.0: 5–6 Deployment (helm — 5, all-in-one манифест — 6 c kuberay-operator): controller-manager, gateway-plugins, metadata-service, gpu-optimizer, redis-master (+kuberay-operator). **Jaeger, otel-collector и prometheus по умолчанию НЕ ставятся** (было в чарте эпохи v0.1.x; сейчас трейсинг/мониторинг — внешние). KubeRay для кластера без RDMA не нужен.

- [x] **Подготовить Helm chart/values для Selectel MKS**
  → `helm/values-selectel-mks.yaml`.
  Форк не требуется: официальный чарт v0.7.0 + слой values поверх `stable.yaml`. Ключевое: Envoy LB Service → Octavia (keep-floatingip, таймауты под LLM-стриминг 1 ч), HA-флаги, закомментированные мирринг-CRaaS/мониторинг. Проверено рендером `helm template` (38 объектов, без ошибок).

- [x] **Описать процесс установки**
  → `docs/02-install-mks.md`. Порядок: Envoy Gateway (v1.2.8, `enableEnvoyPatchPolicy=true`) → CRD → чарт со stable.yaml + values. Альтернатива манифестами. Проверка, обновление (нюанс: `values.yaml` в доках апгрейда тянет `:nightly`), удаление (CRD helm'ом не удаляются), troubleshooting.

- [x] **Инструкция для тестового кластера** (установка AIBrix, тест модели, проверка)
  → `docs/02-install-mks.md` §3–4 + `manifests/vllm-quickstart.yaml` (DeepSeek-R1-Distill-Llama-8B, деплой → curl через LB → проверка /v1/models и chat/completions).

- [x] **Документация по сценариям использования** (multi-replica routing, оптимизация, observability)
  → `docs/05-usage-scenarios.md`: 7 сценариев (routing-алгоритмы с примерами, LoRA-ферма, автоскейлинг, наблюдаемость с Grafana-дашбордами, rate limiting, мульти-движки/гетерогенные GPU) + список «чего не делать без RDMA» + production-заметки.

## Дополнительные пункты

- [x] **Проверить совместимость inference-shaped autoscaling с автоскейлером Selectel**
  → `docs/03-autoscaling.md`.
  Вердикт: **работает с оговорками**. KPA/APA на CA-управляемых GPU-группах (драйверы предустановлены — узкое место старых версий AIBrix закрыто); метрики KPA собирает сам — metrics-server/Prometheus не нужны; HPA-стратегия с LLM-метриками требует custom-metrics-адаптер (нет ни в AIBrix, ни в MKS). 9 оговорок + бюджет холодного старта. Готовый манифест: `manifests/podautoscaler-kpa.yaml`.

- [x] **Тестовый манифест на добавление LoRA-адаптера (возможно от unsloth)**
  → `manifests/lora-adapter.yaml` + `manifests/vllm-lora-base.yaml` + `docs/04-lora-dynamic-loading.md`.
  Сам org unsloth чистых LoRA-адаптеров не публикует (проверено поиском по HF). Выбран адаптер, **обученный через Unsloth**: `ai-blond/Qwen-Qwen2.5-Coder-1.5B-Instruct-lora` (настоящий PEFT LoRA: r=16, ~70 МБ, Apache-2.0, негейченная база Qwen2.5-Coder-1.5B — это же адаптер из сэмплов самих мейнтейнеров AIBrix). Адаптер и файлы проверены через HF API.

## Сопутствующее

- [x] Платформенные заметки по MKS → `docs/06-selectel-mks-notes.md` (версии, GPU-линейка, LB/Octavia, хранилище, registry, лимиты, «не подтверждено»).
- [x] Вердикт «что работает без RDMA» → `docs/01-aibrix-overview.md` §4 (таблица фич) + README.
- [x] Верификация артефактов: helm template рендер чарта v0.7.0 с values — OK; yq-валидация манифестов — OK; сверка полей с CRD-схемами чарта — OK.

## Осталось пользователю (в тестовом кластере)

- [ ] Создать кластер MKS (1.34–1.36) + CPU-нодгруппу + GPU-нодгруппу (драйверы ON), при желании — CA для GPU-группы.
- [ ] Прогнать быстрый старт из README (установка + smoke тест).
- [ ] Прогнать LoRA-тест (docs/04) и KPA-тест (docs/03 + манифест).
- [ ] Проверить egress подов на huggingface.co/docker.io, при необходимости включить мирринг (values, блок CRaaS).
