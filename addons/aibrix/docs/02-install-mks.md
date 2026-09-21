# 02 — Установка AIBrix v0.7.0 в кластер Selectel MKS

> Проверено рендером: чарт v0.7.0 + `dist/chart/stable.yaml` + наш `helm/values-selectel-mks.yaml` собирается без ошибок (38 объектов, включая EnvoyProxy с Octavia-аннотациями).
> Про платформенные ограничения MKS (версии K8s, LB, registry, лимиты) — [docs/06](06-selectel-mks-notes.md).

## 0. Что понадобится

| Что | Требование |
|---|---|
| Кластер MKS | Версия **1.34–1.36** (минимум AIBrix ≈ 1.28 — через Envoy Gateway; см. [docs/01 §6](01-aibrix-overview.md)) |
| Нодгруппы | 1) CPU-группа для контроль-плейна AIBrix (2–4 vCPU достаточно; AIBrix не требует GPU-нод) 2) GPU-группа с предустановленными драйверами (тумблер GPU Drivers) для моделей |
| Инструменты | `kubectl` (из панели MKS), `helm` ≥ 3.8, `git` |
| Сеть | egress на docker.io (aibrix/*), registry-1.docker.io (envoy), huggingface.co (модели). Из корпоративной сети Selectel доступ есть; проверьте из подов при необходимости |
| Автоскейлер | Если планируете масштабировать GPU-группу — включите при создании группы; см. [docs/03](03-autoscaling.md) |

GPU-драйверы в MKS предустановлены (NVIDIA device plugin тоже) — устанавливать GPU Operator не нужно.

## 1. Установка Envoy Gateway (обязательная зависимость)

Envoy Gateway ставится **отдельным чартом** (в чарт AIBrix не входит). Вместе с ним автоматически устанавливаются Gateway API CRD'ки (`gateway.networking.k8s.io` + `gateway.envoyproxy.io`).

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.8 \
  -n envoy-gateway-system --create-namespace \
  --set config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true
```

⚠️ `enableEnvoyPatchPolicy=true` — **обязательно**: AIBrix использует `EnvoyPatchPolicy` для прямого роутинга на выбранный под (`target-pod`) и таймаутов маршрутов.

Проверка:

```bash
kubectl get pods -n envoy-gateway-system
# envoy-gateway-<hash> 1/1 Running
```

## 2. Установка AIBrix (Helm — рекомендованный путь)

Чарт AIBrix **не публикуется в Helm-репозиториях** — ставим из git-клона тега:

```bash
git clone https://github.com/vllm-project/aibrix.git
cd aibrix
git checkout v0.7.0   # пинним релиз

# CRD (helm тоже поставит их при первом install, но доки делают явно — надёжнее для апгрейдов)
kubectl apply -f dist/chart/crds/

# Установка: stable.yaml (образы v0.7.0) + наш values (Octavia и пр.)
helm install aibrix dist/chart \
  -f dist/chart/stable.yaml \
  -f /path/to/aibrix-mks/helm/values-selectel-mks.yaml \
  -n aibrix-system --create-namespace
```

⚠️ **Порядок `-f` важен**: дефолтный `values.yaml` чарта пиннит теги `:nightly` — наш файл идёт строго после `stable.yaml` (побеждает последний).

Что делает `helm/values-selectel-mks.yaml` (см. комментарии внутри):
- `gateway.envoyProxy.replicas=2` + affinity — дата-плейн Envoy как Deployment на system-нодах (лейбл `nodegroup=system` из `infra/01-cluster`; раньше был локальный патч envoyDaemonSet — удалён 09.09.2026, LB AIBrix больше нет);
- `gateway.envoyProxy.service.type=ClusterIP` — балансировщик НЕ создаётся вовсе: единственный публичный вход — LiteLLM (auth-слой), внутрь кластера ходим по стабильному имени `aibrix-gateway.envoy-gateway-system.svc` (Service создаётся terraform'ом в 02-addons; хэш-имя EG-сервиса меняется между деплоями), оператору — `kubectl port-forward`;
- пиннинг всего контроль-плейна AIBrix (controller-manager, gateway-plugin, gpu-optimizer, metadata, redis) на ноды `nodegroup=system` — GPU-ноды Karpenter не тейнчатся, без пиннинга поды уезжали бы на дорогие GPU-ноды;
- `AIBRIX_STATESYNC_ENABLED: "false"` — для одной реплики gateway-plugins (подняли до >1 — переключите в `"true"`, см. [docs/05](05-usage-scenarios.md));
- закомментированные блоки: override ресурсов, мирринг образов через зеркало, `prometheus.enable`, трейсинг.

### Альтернатива: установка манифестами (без helm)

```bash
kubectl apply -f https://github.com/vllm-project/aibrix/releases/download/v0.7.0/aibrix-dependency-v0.7.0.yaml --server-side
kubectl apply -f https://github.com/vllm-project/aibrix/releases/download/v0.7.0/aibrix-core-crds-v0.7.0.yaml --server-side
kubectl apply -f https://github.com/vllm-project/aibrix/releases/download/v0.7.0/aibrix-core-v0.7.0.yaml
```

⚠️ Отличия от helm-пути: (1) в all-in-one core-манифест дополнительно входит `aibrix-kuberay-operator` — нам не нужен, но безвреден; (2) нельзя подложить наш values (аннотации Octavia придётся патчить отдельно на созданном Envoy Gateway Service). Поэтому helm-путь основной.

### KubeRay — не устанавливать

Нужен только для Ray-мульти-нодового распределённого инференса (RDMA-сценарий). Наш кластер без RDMA → пропускаем. Контроллер distributed-inference в AIBrix при отсутствии Ray CRD просто не активируется.

## 3. Проверка установки

```bash
helm list -A                                  # aibrix (aibrix-system), eg (envoy-gateway-system)

kubectl get pods -n aibrix-system
# Ожидаемо (helm-путь, 5 деплойментов):
#   aibrix-controller-manager-<hash>  1/1 Running
#   aibrix-gateway-plugins-<hash>     1/1 Running
#   aibrix-gpu-optimizer-<hash>       1/1 Running
#   aibrix-metadata-service-<hash>    1/1 Running
#   aibrix-redis-master-<hash>        1/1 Running

kubectl get pods -n envoy-gateway-system
#   envoy-gateway-<hash> 1/1 Running                    (контроллер)
#   envoy-aibrix-system-aibrix-eg-<hash> 1/1 Running     (дата-плейн Envoy)

kubectl get gateway,httproute -n aibrix-system
#   Gateway aibrix-eg — Programmed; HTTPRoute aibrix-reserved-router, ...-metadata-endpoint — ResolvedRefs True

# Сервис дата-плейна — ClusterIP, БЕЗ балансировщика (см. выше «зачем»):
kubectl get svc -n envoy-gateway-system
#   envoy-aibrix-system-aibrix-eg-<hash>  ClusterIP  10.x.x.x  80:31810/TCP
```

Дымовой тест цепочки до первого запроса модели — изнутри кластера по
стабильному имени (или операторский port-forward):

```bash
kubectl -n envoy-gateway-system port-forward svc/envoy-aibrix-system-aibrix-eg-<hash> 8888:80 &
curl http://localhost:8888/v1/models/
# Пока моделей нет — вернётся пустой список от metadata-service: {"object":"list","data":[]}
```

Если создаёте LB вручную — проверьте квоту на балансировщики в облачной платформе.

## 4. Дымовой тест: первая модель

```bash
см. addons/inference-charts/README.md (terraform: deploy_models, пресет deepseek-r1-distill-llama-8b-s3)
kubectl rollout status deployment/deepseek-r1-distill-llama-8b --timeout=30m
# (грузится ~16 ГБ весов с HuggingFace)

LB_IP=localhost:8888   # port-forward из §3, либо адрес из приватной сети при LB
curl http://$LB_IP/v1/models/
curl http://$LB_IP/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "routing-strategy: least-request" \
  -d '{
    "model": "deepseek-r1-distill-llama-8b",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

Дальше по сценариям: LoRA — [docs/04](04-lora-dynamic-loading.md), автоскейлинг — [docs/03](03-autoscaling.md) + `manifests/podautoscaler-kpa.yaml`.

## 5. Обновление

```bash
cd aibrix && git fetch --tags && git checkout v0.7.1   # новая версия (пример)

kubectl apply -f dist/chart/crds/                      # CRD НЕ обновляются helm'ом — всегда вручную

helm upgrade aibrix dist/chart \
  -f dist/chart/stable.yaml \
  -f /path/to/aibrix-mks/helm/values-selectel-mks.yaml \
  -n aibrix-system
```

⚠️ В официальных доках команда апгрейда использует `-f dist/chart/values.yaml` — это переключает образы на `:nightly`. Для управляемого стенда держим `stable.yaml` + свой values.

## 6. Удаление

```bash
helm uninstall aibrix -n aibrix-system
helm uninstall eg -n envoy-gateway-system
```

⚠️ `helm uninstall` **не удаляет CRD** AIBrix (семантика `crds/` + осознанное решение, [aibrix#2062](https://github.com/vllm-project/aibrix/issues/2062)). Полная зачистка вместе со всеми CR (PodAutoscaler, ModelAdapter, StormService, KVCache...) и их кастомными объектами:

```bash
kubectl delete -f dist/chart/crds/      # деструктивно: каскадно удалит все CR!
```

## 7. Типовые проблемы

| Симптом | Причина/решение |
|---|---|
| Envoy Gateway не поднимает LB, `EXTERNAL-IP <pending>` | Квота/лимит балансировщиков в облачной платформе; посмотрите события Service |
| Pod'ы aibrix в `ImagePullBackOff` | egress на docker.io закрыт — переопределите репозитории через зеркало (блок в `values-selectel-mks.yaml`) |
| Долгие запросы обрываются ~50–60 с | Не применились аннотации `timeout-client-data`/`timeout-member-data` (проверьте `kubectl get envoyproxy aibrix-custom-proxy-config -o yaml`), либо таймаут выше в цепочке (прокси, WAF) |
| `gateway-plugins` CrashLoop | Redis не поднялся/недоступен; смотрите initContainer (busybox ждёт `redis-cli ping`) |
| Webhook-ошибки при создании Deployment | Секрет `aibrix-webhook-server-cert` заполняется cert-rotator'ом через ~10–30 с после старта controller-manager — дождитесь |
