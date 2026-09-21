# inference-charts

Вендоренный чарт `inference-charts` (версия 0.2.6): генератор
Deployment+Service для
vLLM / Ray / Triton по values-файлу. В этом репозитории — **основной
путь деплоя моделей**: terraform ставит helm-релизы из `deploy_models`
(blueprint.tfvars), веса — из S3 (PVC `models`, csi-s3).

## Поток деплоя (terraform)

```hcl
deploy_models = {
  "deepseek-r1-distill-llama-8b" = { preset = "deepseek-r1-distill-llama-8b-s3" }
  "qwen3-32b"                    = { preset = "qwen3-32b-s3" }
}
```

- ключ = имя модели = `inference.serviceName` = `--served-model-name`
  (инвариант AIBrix, роутинг aibrix-шлюза);
- `preset` — файл `values-<preset>.yaml` рядом с этим README;
- `values` — точечные переопределения поверх пресета (map, yamlencode).

Ручной путь (эксперименты): `helm install <имя> addons/inference-charts/chart
-f values-selectel-mks.yaml -f values-<preset>.yaml`.

## Файлы

- `values-selectel-mks.yaml` — базовый пресет Selectel: зеркало registry,
  пин vLLM v0.11.0, монтирование PVC `models` (SC csi-s3), отключение
  HF-токена (веса из S3), `strategy: Recreate`, порт/лейблы Service под
  ServiceMonitor observability (`metrics`, `observability.ai/vllm: "true"`),
  щедрый startupProbe (холодный S3 через geesefs);
- `values-deepseek-r1-distill-llama-8b-s3.yaml` — smoke-модель 8B (~16 ГБ):
  `gpuNames: [l4, a5000, rtx4090-24]`, статический LoRA (`--enable-lora`,
  `--lora-modules` из S3) + env для динамической загрузки (aibrix
  ModelAdapter);
- `values-qwen3-32b-s3.yaml` — 32B bf16 (~65 ГБ): `gpuMinVramGb: 80`;
- справочные пресеты (перенесены из ветки backup-before-rebase, ручной helm —
  не дефолт deploy_models):
  - `values-kimi-k3-vllm.yaml` — Kimi-K3, 8×GPU (TP=8), веса из HF при старте
    (нужен HF-токен: не накладывать выключение `hfTokenSecret` из базового
    пресета — задать `hfTokenSecret.enabled: true`);
  - `values-llama-3-8b-instruct-s3.yaml` — Llama-3-8B из S3 (PVC `models`);
    адаптирован: старый вариант ветки (modelPath `s3://` + RUNAI-стример +
    env-креды S3) опирался на удалённую из чарта ветку `s3CredentialsSecret`;
  - `values-deepseek-r1-distill-llama-8b-ray-vllm-gpu.yaml` — Ray-вариант
    deepseek-8B (RayCluster вместо Deployment; не проверен);
  - `values-s3-copy-glm-5-2.yaml`, `values-s3-copy-llama3-8b.yaml` — Job'ы
    s3ModelCopy (загрузка весов HF → S3, альтернатива Job'у из
    `addons/models/`); требуют Secret `selectel-s3-credentials`.
- `chart/values-*.yaml` (апстримные, облачная специфика источника удалена:
  пресеты недоступных ускорителей/s3copy убраны, образы →
  `vllm/vllm-openai`, `instanceType` → комментарий) — справочник параметров
  моделей. Для Selectel их нужно адаптировать (gpuNames/gpuMinVramGb,
  S3-алиас в modelPath).

## Выбор GPU (Karpenter + DRA)

- **`gpuNames`** — список имён GPU-пулов (лейбл `gpu:` на NodePool'ах,
  `addons/karpenter/ru-<регион>/`). Список — fallback: Karpenter берёт самый
  дешёвый подходящий флейвор из доступных в зоне.
- **`gpuMinVramGb`** — минимальная VRAM (лейбл `gpu-vram` на NodePool'ах,
  оператор `Gt`): любая карта нужного объёма, самая дешёвая.
- Оба → affinity `required` с AND по одному nodeSelectorTerm.
- **Реквесты GPU остаются classic** (`nvidia.com/gpu`): Karpenter не
  провижинит поды с явными ResourceClaim (проверено, см.
  `addons/dra-test/README.md`). DRA-учёт карт при установленном DRA-драйвере
  обеспечивает мостик extended-resources: он сам создаёт ResourceClaim для
  classic-запросов. Шаринг карты по VRAM — только вручную через RCT (dra-test).

## Динамические LoRA (aibrix ModelAdapter)

Да, чарт поддерживает. Три части:

1. **Базовый деплой** — `framework: aibrix` (в базовом пресете): лейбл
   `model.aibrix.ai/name` на подах — по нему контроллер ModelAdapter
   находит поды (`podSelector`), а aibrix-шлюз маршрутизирует запросы.
2. **Предусловия в values модели** (уже в пресете
   `deepseek-r1-distill-llama-8b-s3`): `modelParameters.enable-lora`,
   `max-lora-rank`/`max-loras` и env `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True`
   (API `/v1/load_lora_adapter`).
3. **Сам адаптер** — CR `ModelAdapter` (kubectl, вне чарта и terraform — CRD
   неизвестны на plan, инвариант 2 AGENTS.md): образец
   `addons/models/modeladapter-finqa.yaml` (direct-режим, `artifactURL` —
   путь в S3-томе). `kubectl apply/delete` — загрузка/выгрузка без рестарта
   пода; aibrix-шлюз роутит по `model = <имя CR>`.

## Зависимости (должны быть в кластере)

- PVC `models` (SC `csi-s3`) — `install_csi_s3` в 02-addons + Job загрузки
  весов из `addons/models/` (запись в `hf_models`, blueprint.tfvars);
- GPU-пул Karpenter с лейблами `gpu: <имя>` / `gpu-vram: "<ГБ>"`;
- для метрик в Grafana — observability-стек (ServiceMonitor `vllm`).

## Локальные патчи вендоренного чарта

Отличия от апстрима (полный список; маркеры в шаблонах не ставятся,
источник истины — этот раздел):

- `chart/templates/vllm-deployment.yaml`:
  - `hfTokenSecret.enabled` — выключение монтирования HF-токена (веса из
    S3, токен не нужен); апстрим монтирует безусловно;
  - `extraVolumes` / `extraVolumeMounts` — PVC csi-s3 с весами;
  - `nodeSelector` / `tolerations` — прямая адресация нод;
  - `gpuNames` / `gpuMinVramGb` — nodeAffinity на лейблы GPU-пулов;
  - `service.portName` — имя порта Service под ServiceMonitor
    observability (`metrics`; апстрим жёстко `http`);
  - `strategy` — Recreate в пресете Selectel: одиночная GPU + RollingUpdate
    зависает на апдейте (новый под Pending, GPU занят старым — тот же
    вывод, что в `addons/models/`).
- `chart/values.yaml` — ключи для патчей выше (дефолты сохраняют поведение
  апстрима: `hfTokenSecret.enabled: true`, `portName: http` и т.п.).

- `chart/templates/s3-model-copy.yaml` — образ Job'а s3ModelCopy из зеркала
  registry Selectel (`python:3.11-slim`) вместо апстримного образа
  (недоступен из сети кластера), dnf-шаг установки python убран;
- `chart/templates/_helpers.tpl` — `s3ModelCopyAffinity`: nodeAffinity по
  лейблу Karpenter Selectel `karpenter.k8s.selectel/instance-local-disk`
  (ключ values — `requireLocalDisk`) вместо апстримных лейблов
  instance-local-nvme / instance-network-bandwidth (недоступны в MKS);
- вырезаны ветки недоступных в MKS ускорителей из шаблонов
  (`vllm-deployment`, `ray-vllm-deployment`, `diffusers-deployment`,
  `_helpers.tpl`, `NOTES.txt`) и `chart/values.yaml` (блоки ресурсов,
  комментарии); поддерживается только ускоритель gpu.

Шаблоны triton/llama-cpp не патчились — для Selectel-сценариев
достаточно vllm/aibrix/ray-режимов чарта.
