# Модели vLLM — загрузка весов в S3 и LoRA

Деплой моделей — чарт `addons/inference-charts/` (helm-релизы из terraform:
`deploy_models` в blueprint.tfvars). Здесь — Job загрузки весей из
HuggingFace в S3 и LoRA-специфика (ModelAdapter).

## Пайплайн (по умолчанию)

```
Job hf-models-upload:  huggingface.co ──► PVC "models" (geesefs → S3)
                                        /models/<alias>/…
vLLM (helm, чарт):     positional arg /models/<alias>
```

- **Загрузка**: `terraform apply` 02-корня создаёт/пересоздаёт Job
  (пересоздание — при изменении списка `hf_models`). Job
  монтирует PVC `models` (RWX) и качает файлы прямо в том — geesefs сам
  пишет их в S3-контейнер (креды не нужны, они у драйвера csi-s3).
  Существующие файлы пропускаются по размеру — перезапуск job'ы безопасен.
  После загрузки — сверка размеров всех файлов с HuggingFace, `os.sync()`
  и пауза 300с (см. «Грабли»: фоновая выгрузка geesefs).
  Токен HF (переменная `huggingface_token` в blueprint, прикладывается
  в Secret `hf-token` → env `HF_TOKEN`) убирает rate-limit анонимной
  загрузки; смена/добавление пересоздаёт Job.
- **Монтирование**: [csi-s3](https://github.com/yandex-cloud/k8s-csi-s3)
  (geesefs) — StorageClass csi-s3 c `singleBucket: <bucket>`: каждый PVC
  получает СВОЙ подкаталог `pvc-<uid>` в контейнере (не корень бакета!).
  Маппинг модели = каталог `<alias>` в томе: vLLM — позиционный аргумент
  `/models/<alias>` (vLLM v0.11 убрал опцию `--model`).

## Деплой моделей (чарт inference-charts)

Тумблер `deploy_models` в blueprint.tfvars — map имя → `{preset, values}`:

```hcl
deploy_models = {
  "deepseek-r1-distill-llama-8b" = { preset = "deepseek-r1-distill-llama-8b-s3" }
  "qwen3-32b"                    = { preset = "qwen3-32b-s3" }
}
```

Имя модели = serviceName = `--served-model-name` (инвариант AIBrix);
пресеты — `addons/inference-charts/values-<preset>.yaml`. Выбор GPU:
`gpuNames` (список пулов, fallback по цене) или `gpuMinVramGb`
(любая карта с VRAM больше N ГБ — Karpenter берёт самую дешёвую).
Подробнее — `addons/inference-charts/README.md`.

## Выбор GPU для Qwen3-32B

32.8B параметров ≈ 65 ГБ весов bf16 + KV-кэш: карты 24/48 ГБ не подходят
(без квантизации), нужен 1× GPU ≥80 ГБ. Из пулов кластера (ru-6) это
**H200** (141 ГБ) — с запасом на KV-кэш и рост контекста. A100-80 есть
только в ru-7 (другой пул — не используется). В пресете — `gpuMinVramGb: 80`.

## Установка

```bash
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
cd infra/02-addons && terraform apply
# оператор csi-s3 ставится terraform (install_csi_s3), PVC создаётся terraform
kubectl -n default get job hf-models-upload -w    # статус загрузки весов
kubectl -n default get pvc models                # Bound после старта драйвера
```

Порядок: csi-s3 → Job (загрузка в том) → деплой модели (поды с PVC).
Ждать завершения Job не обязательно: vLLM увидит файлы по мере появления,
но проверять инференс — после Completed.

## LoRA-адаптеры

Адаптеры — те же записи в `hf_models` (alias = каталог в томе): job качает их
вместе с моделями (GGUF/ONNX-конверсии в репозиториях отсекаются — только
safetensors/json). Два способа поднять поверх базовой модели:

| | Статический (`--lora-modules`) | AIBrix ModelAdapter (quickstart) |
|---|---|---|
| Когда грузится | при старте пода | динамически, без рестарта |
| Управление | правка values + helm upgrade | `kubectl apply/delete` CR |
| Маршрут в LiteLLM | напрямую в сервис пода (**порт 8000** — сервис не слушает 80; без порта запрос молча виснет до 504 шлюза) | через aibrix-gateway, как у базовых моделей |
| Требования | `--enable-lora --max-lora-rank` | то же + env `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True` |

Статический способ — в пресете `deepseek-r1-distill-llama-8b-s3`
(`enable-lora`, `lora-modules` в `modelParameters`, env для runtime-загрузки).

### Quickstart: LoRA через aibrix ModelAdapter (проверено)

Предусловия уже в пресете deepseek: `--enable-lora` и env
`VLLM_ALLOW_RUNTIME_LORA_UPDATING`. Адаптер — запись в `hf_models`
(`deepseek-lora` в blueprint.tfvars). Дальше одна команда:

```bash
kubectl apply -f addons/models/modeladapter-finqa.yaml
kubectl get modeladapter deepseek-finqa -w    # Pending -> Running (~10 c)
```

Как работает: БЕЗ сайдкара контроллер aibrix сам вызывает
`/v1/load_lora_adapter` у vLLM с `lora_path` = `artifactURL` (путь в томе —
ничего не скачивается), создаёт Service/EndpointSlice с именем CR →
aibrix-шлюз маршрутизирует `model = <имя CR>`. `kubectl delete modeladapter` —
выгрузка адаптера, под не рестартует. Запись в `model_list` LiteLLM — как у
базовых моделей (aibrix-gateway).

⚠ Сайдкар-режим (`aibrix-runtime` + `artifactURL: huggingface://`) в aibrix
v0.7.0 с багом: при ретрае загрузки возвращает корень вместо
`snapshots/<rev>` («No adapter found») и выкачивает весь репозиторий с
GGUF-мусором. Пример сайдкар-режима: `addons/aibrix/manifests/lora-adapter.yaml`
(не проверен; там же — требования сайдкар-пути).

Запрос через токен LiteLLM (актуально для обоих способов):

```bash
MK=$(kubectl -n litellm get secret litellm-masterkey -o jsonpath='{.data.*}' | base64 -d)
KEY=$(curl -s -X POST https://ai.<домен>/key/generate \
  -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d '{"key_alias":"lora","models":["deepseek-r1-distill-llama-8b","deepseek-r1-distill-llama-8b-lora"],"max_budget":1}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
curl -s https://ai.<домен>/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-r1-distill-llama-8b-lora","max_tokens":150,
       "messages":[{"role":"user","content":"..."}]}'
```

Проверено 2026-09-11: адаптер
li-long/DeepSeek-R1-Distill-Llama-8B-lora-financial-qa-model (r=16) поверх
deepseek-8b, ответ 200 за ~4 c.

## Грабли

- **Асинхронная выгрузка geesefs на выходе Job'а**: rename скачанного
  файла (`.incomplete` → итоговое имя) geesefs выполняет фоновой S3-копией
  на несколько ГБ. Если под завершается сразу после скрипта, копия
  обрывается: `.incomplete` остаётся в бакете, итогового файла нет, Job
  при этом «успешен». Поэтому скрипт Job'а сверяет размеры, зовёт `os.sync()` и спит 300с после загрузок.
- **geesefs и mmap**: safetensors читается mmap-ом (random access). GeeseFS
  держит в памяти кэш (`--memory-limit 1000` по дефолту csi-s3, МБ на ноду)
  и префетчит — первый проход по холодным весам медленнее локального диска.
  Если старт vLLM таймаутится — увеличить memory-limit в mountOptions SC
  и/или startupProbe failureThreshold.
- **префикс тома**: csi-s3 монтирует не корень бакета, а подкаталог
  `pvc-<uid>` — загруженное в корень бакета мимо тома не видно (проверено
  2026-09-11; поэтому job качает прямо в том, креды S3 job'у не нужны).
- **`reclaimPolicy: Retain`** у SC csi-s3 — удаление PVC не удаляет веса
  (новый PVC получит другой префикс pvc-<uid>: весы придётся перезалить
  job'ой, либо скопировать внутри бакета).
- **PVC immutable**: смена accessModes/размера — удаление PVC+PV и новый apply.
- **CSI-драйвер на GPU-нодах**: DaemonSet csi-s3 должен успеть подняться на
  новой karpenter-ноде до старта vLLM-пода (иначе NodePublishTimeout,
  karpenter пересоздаст под). Кратковременный Pending — штатно.
- **Job и `force_new`**: terraform пересоздаёт Job только при изменении
  `hf_models`; перезапустить вручную — `kubectl -n default delete job`.
- Образы для Job качаются через зеркало `docker-registry.selectel.ru`
  (pull-through); `python:3.12.9-slim` — реальный тег (sha-теги зеркала
  меняются, пинить нельзя).
