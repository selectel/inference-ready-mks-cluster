# 04 — Динамическая загрузка LoRA-адаптеров в AIBrix

> Статус: проверено. Все YAML ниже — адаптация официальных сэмплов aibrix v0.7.0 (`samples/adapter/base.yaml`, `samples/adapter/adapter.yaml`); адаптер на HuggingFace проверен через HF API (файлы, размеры, конфиг).
> Файлы пакета: [`manifests/vllm-lora-base.yaml`](../manifests/vllm-lora-base.yaml) + [`manifests/lora-adapter.yaml`](../manifests/lora-adapter.yaml).

## TL;DR

1. Разворачиваем базу `qwen-coder-1-5b-instruct` (Qwen2.5-Coder-1.5B, ~3 ГБ) + сайдкар `aibrix/runtime` — `manifests/vllm-lora-base.yaml`;
2. Создаём CR `ModelAdapter` с `artifactURL: huggingface://ai-blond/Qwen-Qwen2.5-Coder-1.5B-Instruct-lora` — `manifests/lora-adapter.yaml`;
3. Ждём фазу `Running`, обращаемся к адаптеру как к обычной модели: `"model": "qwen-code-lora"` через шлюз.

RDMA не требуется: загрузка LoRA ортогональна KV-трансферам, всё работает на одиночной GPU-ноде.

## 1. Как это работает (механизм)

```
ModelAdapter CR (kubectl apply)
      │
      ▼
aibrix-controller-manager ── валидирует artifactURL
      │                      (s3://, gcs://, tos://, huggingface://, hf://, /путь)
      │                      селектирует Ready-поды по spec.podSelector
      ▼
POST http://<pod>:8080/v1/lora_adapter/load   ← сайдкар aibrix-runtime
      │
      ├── публичный HF: проброс прямо в движок
      │    (контроллер срезает huggingface:// → repo id,
      │     vLLM сам скачивает адаптер)
      │
      └── delegated-режим (s3/gcs/tos/приватный HF):
            runtime скачивает артефакт в /tmp/aibrix/adapters/<name>,
            передаёт ЛОКАЛЬНЫЙ путь дальше
      ▼
POST http://localhost:8000/v1/load_lora_adapter  ← vLLM
      { "lora_name": <имя ModelAdapter>, "lora_path": <...> }
      ▼
Адаптер зарегистрирован в vLLM (виден в /v1/models)
      ▼
Контроллер создаёт K8s Service + EndpointSlice с именем адаптера
      → фаза Running
```

- **Фазы жизненного цикла:** `Pending → Scheduled → Loading → Bound → Running` (`kubectl describe modeladapter <name>`).
- **Надёжность:** до 5 ретраев на под с экспоненциальной задержкой (5с→10с→20с→40с→80с), затем автоматическое переключение на другой здоровый под.
- **Выгрузка:** удаление CR `ModelAdapter` → `/v1/unload_lora_adapter` + удаление сгенерированных Service/EndpointSlice.
- **Шлюз:** специального «lora-aware» алгоритма нет — работает обычная маршрутизация по имени модели: контроллер создаёт Service с именем адаптера, EndpointSlice указывает на поды-хозяева. Это сознательно ломает модель «1 под = 1 сервис»: один под с N LoRA принадлежит N сервисам.

## 2. Требования к базовому Deployment (AIBrix сам это НЕ ставит!)

| Что | Зачем |
|---|---|
| Лейблы `model.aibrix.ai/name: <name>` + `model.aibrix.ai/port: "8000"` | Дискавери модели шлюзом; `name` = имя Service = `--served-model-name` (жёсткая связка) |
| Лейбл `adapter.model.aibrix.ai/enabled: "true"` — и в Deployment, и в pod template | Селекция подов контроллером ModelAdapter |
| Флаги vLLM: `--enable-lora`, `--max-loras 4`, `--max-cpu-loras 4` | Включение LoRA-пути и лимиты плотности адаптеров (`max_cpu_loras ≥ max_loras`) |
| Env `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True` | Открывает эндпоинты `/v1/load_lora_adapter`/`/v1/unload_lora_adapter` в vLLM — без этого загрузка не состоится |
| Сайдкар `aibrix/runtime` (:8080, `INFERENCE_ENGINE=vllm`, `INFERENCE_ENGINE_ENDPOINT=http://localhost:8000`) | Начиная с v0.2.0 контроллер по умолчанию ходит через сайдкар; обязателен для s3/приватного HF |
| Общий том `adapter-storage` (emptyDir) в /tmp/aibix/adapters | Разделение скачанных артефактов между сайдкаром и движком (delegated-режим) |

⚠️ `VLLM_ALLOW_RUNTIME_LORA_UPDATING` — поверхность, которую vLLM сам помечает как «should ONLY be used for local development» и которая **несовместима с `api_server_count > 1`**. Ценность AIBrix в том, что динамической загрузкой управляет контроллер изнутри кластера (RBAC + ретраи), а порт 8000 не открыт наружу — держите его недоступным снаружи.

## 3. Пошаговая инструкция

```bash
# 1. База + сайдкар + Service
kubectl apply -f manifests/vllm-lora-base.yaml
kubectl rollout status deployment/qwen-coder-1-5b-instruct --timeout=30m

# 2. Адаптер
kubectl apply -f manifests/lora-adapter.yaml

# 3. Ждём готовности (фаза Running)
kubectl wait --for=jsonpath='{.status.phase}'=Running \
  modeladapter/qwen-code-lora --timeout=10m
# Наблюдение: kubectl describe modeladapter qwen-code-lora
#             kubectl get svc qwen-code-lora   # сгенерированный сервис

# 4. Проверяем (LB AIBrix — внутренний: из приватной сети или port-forward)
LB_IP=$(kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

# Базовая модель
curl http://$LB_IP/v1/completions -H "Content-Type: application/json" -d '{
  "model": "qwen-coder-1-5b-instruct",
  "prompt": "San Francisco is a", "max_tokens": 128, "temperature": 0 }'

# Тот же под, тот же base — но через LoRA-адаптер (просто другое имя модели!)
curl http://$LB_IP/v1/completions -H "Content-Type: application/json" -d '{
  "model": "qwen-code-lora",
  "prompt": "San Francisco is a", "max_tokens": 128, "temperature": 0 }'
```

Сравните ответы: адаптер дообучен для code-задач, стилистика будет отличаться. Если vLLM запущен с `--api-key` — продублируйте ключ в `spec.additionalConfig.api-key` ModelAdapter.

## 4. Тестовый адаптер: почему именно этот

**`ai-blond/Qwen-Qwen2.5-Coder-1.5B-Instruct-lora`** — [репозиторий](https://huggingface.co/ai-blond/Qwen-Qwen2.5-Coder-1.5B-Instruct-lora) (публичный, Apache-2.0):

- **обучен с помощью Unsloth** (от `unsloth/qwen2.5-coder-1.5b-instruct-bnb-4bit`). Сам org `unsloth` чистых LoRA-адаптеров не публикует (проверено поиском по HF — 0 результатов), так что это ближайший «unsloth»-вариант;
- настоящий PEFT-LoRA: `adapter_config.json` + `adapter_model.safetensors` **~70 МБ**;
- конфигурация: `peft_type: LORA`, **r=16**, `alpha=16`, таргеты `q/k/v/o/gate/up/down proj` — стандартные линейные модули, vLLM поддерживает полностью; r=16 влезает в дефолтный `--max-lora-rank`;
- база Qwen2.5-Coder-1.5B — **негейченная** (токен HF не нужен), влезает в любой GPU;
- именно этот адаптер используют сэмплы и CI самих мейнтейнеров AIBrix.

Альтернативы (тоже проверены на существование и содержимое):

| Адаптер | Размер | База | Примечание |
|---|---|---|---|
| `yard1/llama-2-7b-sql-lora-test` | ~39 МБ, r=8 | `meta-llama/Llama-2-7b-hf` | классика из доков vLLM (SQL/function calling); база **гейчена** (нужен HF_TOKEN), таргеты включают `embed_tokens`/`lm_head` с файлом `new_embeddings.safetensors` (vLLM его игнорирует) |
| `jeeejeee/llama32-3b-text2sql-spider` | ~1.5 ГБ | `meta-llama/Llama-3.2-3B-Instruct` | пример из актуальных доков vLLM; очень высокий rank — не для первого теста |

## 5. Форматы `artifactURL`

| Префикс | Кто скачивает | Комментарий |
|---|---|---|
| `huggingface://org/repo` (алиас `hf://`) | vLLM напрямую / runtime | публичные репо — без токенов |
| `s3://bucket/path` | только runtime-сайдкар | нужен `spec.credentialsSecretRef` + общий том |
| `gs://...`, `tos://...` | runtime-сайдкар | аналогично |
| `/abs/path` | никто — смонтируйте сами | NFS/общая ФС, ответственность пользователя |

Собственные адаптеры (после файнтюна) выкладывайте в HF-репозиторий или S3-совместимое хранилище (в Selectel — Object Storage с S3-API) и указывайте `artifactURL`.

## 6. Ограничения (по документации v0.7.0)

- Поддерживаемый движок — **vLLM** (в коде контроллера есть пути SGLang, но документированный путь — vLLM);
- `spec.replicas` — только `1` или опущено (= загрузить на **все** подходящие поды, рекомендуется для отказоустойчивости);
- `--max-loras` — лимит **различных** адаптеров в батче, не количества CR ModelAdapter;
- загрузка — per-pod: при `replicas: 1` гибель пода = пере-плейсмент адаптера контроллером;
- жёсткая связка имён: Service = `--served-model-name` = `model.aibrix.ai/name`, иначе маршрутизация сломается;
- приватные хранилища требуют runtime-сайдкар (прямой режим контроллер→vLLM работает только с публичным HTTP(S)/HF).

## 7. Troubleshooting

```bash
kubectl describe modeladapter qwen-code-lora      # фаза + conditions
kubectl logs -n aibrix-system deployment/aibrix-controller-manager
kubectl logs deployment/qwen-coder-1-5b-instruct -c vllm-openai | grep -i lora
kubectl get svc,endpointslices -l model.aibrix.ai/name=qwen-code-lora
```

| Симптом | Причина |
|---|---|
| Висит `Pending` | podSelector не совпадает с лейблами подов / поды не Ready |
| Висит `Loading` | недоступный `artifactURL`, HF-аутентификация, нет `VLLM_ALLOW_RUNTIME_LORA_UPDATING` (смотрите логи vLLM-контейнера) |
| `Running`, но запрос 404 | не совпало имя модели в запросе с именем ModelAdapter; проверьте сгенерированный Service |

## Источники

- [LoRA Dynamic Loading — официальная документация](https://aibrix.readthedocs.io/latest/features/lora-dynamic-loading.html)
- Сэмплы v0.7.0: [base.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/adapter/base.yaml) · [adapter.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/adapter/adapter.yaml) · [adapter-multi-lora.yaml](https://github.com/vllm-project/aibrix/blob/v0.7.0/samples/adapter/adapter-multi-lora.yaml)
- [vLLM: Dynamically serving LoRA adapters](https://docs.vllm.ai/en/stable/features/lora.html)
- Адаптер: https://huggingface.co/ai-blond/Qwen-Qwen2.5-Coder-1.5B-Instruct-lora
