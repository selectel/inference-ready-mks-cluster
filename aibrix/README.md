# AIBrix на Selectel Managed Kubernetes

Пакет материалов для развёртывания **AIBrix v0.7.0** в кластере MKS: исследование, values, манифесты, инструкции.

## Главный вывод

**AIBrix полностью оправдан на MKS-кластере без RDMA.** Ядро AIBrix — это CPU-ный контроль-плейн (~2.5 vCPU / ~2.5 GiB поверх кластера): LLM-шлюз с 19 алгоритмами маршрутизации и rate limiting'ом, inference-shaped автоскейлинг (KPA/APA), менеджер LoRA-адаптеров, реестр моделей и Batch API, наблюдаемость. Всё это документировано для одиночных GPU-нод с обычной сетью.

Без RDMA не работают только сценарии распределённого инференса: мульти-нодовый TP/PP через Ray, L2 cross-engine KV-cache (InfiniStore), кросс-нодовый KV-трансфер при P/D-дисагрегации. Полная карта — [docs/01 §4](docs/01-aibrix-overview.md).

## Состав пакета

| Файл | Что внутри |
|---|---|
| `docs/01-aibrix-overview.md` | Компоненты aibrix-system, CRD, карта фич → RDMA, связь с ai-on-eks, обоснование деплоя |
| `docs/02-install-mks.md` | Установка: Envoy Gateway → AIBrix (helm/манифесты), проверка, дымовой тест, обновление, удаление, troubleshooting |
| `docs/03-autoscaling.md` | Inference-shaped autoscaling × автоскейлер Selectel: вердикт **«работает с оговорками»** + 9 оговорок |
| `docs/04-lora-dynamic-loading.md` | Динамическая загрузка LoRA: механизм, требования к vLLM, адаптер (обучен через Unsloth) |
| `docs/05-usage-scenarios.md` | Сценарии: routing-алгоритмы, LoRA-ферма, автоскейлинг, observability, rate limiting, **P/D-дисагрегация (Сценарий 8)**; production-заметки |
| `docs/06-selectel-mks-notes.md` | Платформа MKS: версии K8s, GPU-линейка, Octavia LB, CRaaS, лимиты, пробелы |
| `helm/values-selectel-mks.yaml` | Values поверх официального чарта v0.7.0: Octavia-аннотации (floating IP, таймауты под стриминг), HA-флаги, заготовки под CRaaS-мирринг и мониторинг |
| `manifests/vllm-quickstart.yaml` | Дымовой тест: DeepSeek-R1-Distill-Llama-8B одним Deployment |
| `manifests/vllm-lora-base.yaml` | База для LoRA: Qwen2.5-Coder-1.5B + сайдкар aibrix/runtime + Service |
| `manifests/lora-adapter.yaml` | CR ModelAdapter: адаптер, обученный через Unsloth (ai-blond/Qwen-...-lora, r=16, ~70 МБ) |
| `manifests/podautoscaler-kpa.yaml` | CR PodAutoscaler: KPA по gpu_cache_usage_perc |
| `manifests/stormservice-pd-1p1d.yaml` | PoC: P/D-дисагрегация prefill/decode на одной ноде (StormService + NIXL, без RDMA — проверка механики) |

`CHECKLIST.md` — прогресс по исходному чеклисту задачи.

## Быстрый старт

```bash
# 0. Кластер MKS 1.34–1.36: CPU-нодгруппа + GPU-нодгруппа (драйверы включены)

# 1. Envoy Gateway (обязательная зависимость)
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.8 \
  -n envoy-gateway-system --create-namespace \
  --set config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true

# 2. AIBrix v0.7.0 (чарт публикуется только в git-репозитории проекта)
git clone https://github.com/vllm-project/aibrix.git && cd aibrix && git checkout v0.7.0
kubectl apply -f dist/chart/crds/
helm install aibrix dist/chart \
  -f dist/chart/stable.yaml \
  -f <путь>/aibrix-mks/helm/values-selectel-mks.yaml \
  -n aibrix-system --create-namespace

# 3. Дымовой тест
kubectl apply -f <путь>/aibrix-mks/manifests/vllm-quickstart.yaml
LB_IP=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
curl http://$LB_IP/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"deepseek-r1-distill-llama-8b","messages":[{"role":"user","content":"hello"}]}'

# 4. LoRA (docs/04): база + адаптер — и обращаемся к адаптеру как к обычной модели
kubectl apply -f <путь>/aibrix-mks/manifests/vllm-lora-base.yaml
kubectl apply -f <путь>/aibrix-mks/manifests/lora-adapter.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Running modeladapter/qwen-code-lora --timeout=10m
```

## Версии, на которых всё проверено/сверено

| Компонент | Версия |
|---|---|
| AIBrix (чарт + CRD + доки) | **v0.7.0** — тег-коммит `c546589` |
| Envoy Gateway | v1.2.8 (минимум K8s 1.28) |
| vLLM (LoRA-сэмпл) | `vllm/vllm-openai:v0.24.0` (пин из сэмплов мейнтейнеров) |
| Сайдкар | `aibrix/runtime:v0.7.0` |
| MKS | 1.34–1.36 |

Верификация пакета: `helm template` чарта v0.7.0 с `stable.yaml` + наш values — рендер без ошибок (38 объектов, Octavia-аннотации в EnvoyProxy); все манифесты прошли yq-валидацию и сверены с CRD-схемами из чарта.

## Известные допущения

- Сеть подов → huggingface.co / docker.io из кластера MKS **не проверялась** (нет кластера под рукой) — при проблемах см. блок миррингa в values и troubleshooting в docs/02 §7.
- Хэш в имени LB-сервиса (`envoy-aibrix-system-aibrix-eg-<hash>`) определяется при деплое.
- Аннотации таймаутов Octavia — по документации Selectel; фактические лимиты выше по цепочке (прокси, firewall) не исследовались.
