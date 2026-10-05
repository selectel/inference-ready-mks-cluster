# Тест DRA (Dynamic Resource Allocation) на MKS

> ## ⚠ ТЕСТОВЫЙ СЦЕНАРИЙ (не production)
>
> **Рабочий production-путь — classic**: `nvidia.com/gpu` через device plugin
> (ставит gpu-operator, `addons/gpu-operator/`, ClusterPolicy-режим) +
> affinity по лейблам пулов. DRA переведён в тест по одной причине:
>
> - **Karpenter не провижинит ноды под DRA-поды.** Подтверждено по исходникам
>   (git.selectel.org/mks/karpenter-provider-selectel v0.3.1 + stage, ядро
>   sigs.k8s.io/karpenter v1.14.0): провайдер не заполняет
>   `cloudprovider.InstanceType.DynamicResources` — 0 упоминаний в pkg/ форка.
>   Симуляция DRA-аллокации берёт шаблоны устройств ТОЛЬКО оттуда → «no
>   instance type can satisfy the allocation» → нода не создаётся. Обход —
>   триггер-под (manifests/node-trigger.yaml). Заполнить извне
>   (NodePool/NodeClass/NodeOverlay) нельзя: у этих API нет DRA-полей.
>
> Всё технически работает end-to-end (проверено): драйвер,
> DRA-плагин, шаринг карты по VRAM, vLLM с memory-claim. Развернуть DRA
> можно, пока вы сами поднимаете/держите GPU-ноды — но без автоскейлинга
> под DRA-нагрузку. Пересмотреть при релизе Selectel Karpenter с
> DynamicResources.
>
> ## Состав
>
> ```
> chart/                      vendored kubernetes-sigs/dra-driver-nvidia-gpu v0.5.0
>                             (GitHub-тег). СТАВИТСЯ РЯДОМ с device plugin'ом
>                             из gpu-operator — через осознанный override
>                             gpuResourcesEnabledOverride (см. values).
> values-selectel-mks.yaml    ConsumableShares + CONSUMABLE_SHARES=memory
>                             (шаринг карты по памяти) + override совмещения
>                             + nvidiaDriverRoot: /run/nvidia/driver
>                             (драйвер от gpu-operator'а; с дефолтом «/»
>                             init-контейнер зависает в ожидании nvidia-smi)
> manifests/                  RCT-примеры, node-trigger (обход провижининга),
>                             karpenter-dra-rbac (для IGNORE_DRA_REQUESTS=false)
> ```
>
> ⚠ **Двойная аллокация**: device plugin и DRA-драйвер не знают друг о друге —
> одна и та же карта может быть выдана и classic-поду, и DRA-claim'у.
> NVIDIA запрещает совмещение по умолчанию (валидация чарта) до GA KEP 5004
> (DRAExtendedResource, делает DRA-драйвер источником и для classic-реквестов;
> на MKS не включить — feature gates control-plane не подконтрольны).
>
> ## Грабли
>
> - **Стейл driver-root после рестарта драйвер-DS на ноде** (проверено):
>   gpu-operator перезапускает под драйвера (upgrade) и
>   пересоздаёт `/run/nvidia/driver`; под DRA-плагина держит bind-маунт на
>   старую (теперь пустую) версию каталога → kubelet-подготовка падает
>   «FailedPrepareDynamicResources: ... invalid CDI Spec: empty device
>   edits». Лечение — рестарт пода плагина на этой ноде
>   (`kubectl -n nvidia-dra-driver delete pod --field-selector
>   spec.nodeName=<нода>`); хост при этом видит драйвер нормально
>   (проверяется подом с hostPath `/`).
> - **Classic-поды с nvidia.com/gpu могут получить автосгенерированный
>   claim** (аннотация `resource.kubernetes.io/extended-resource-claim`,
>   мостик extended-resources в драйвере): такой claim аллоцирует карту и
>   занимает ВСЮ её capacity в DRA-учёте → на этой ноде другие DRA-claim'ы
>   уже не поместятся (наблюдение: qwen3-32b, consumedCapacity =
>   вся карта; старый под deepseek без claim'а — бриджинг действует на
>   поды, создаваемые после установки драйвера).
>
> ## Установка / проверка
>
> ```bash
> export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
> # предусловие: gpu-operator в classic-режиме (драйвер уже на нодах)
> helm upgrade --install nvidia-dra-driver addons/dra-test/chart \
>   -n nvidia-dra-driver --create-namespace \
>   -f addons/dra-test/values-selectel-mks.yaml --wait
> kubectl apply -f addons/dra-test/manifests/resourceclaim-templates.yaml
> # smoke: под с claim'ом 8Gi → kubectl exec nvidia-smi
> ```
>
> Проверено: сосуществует с device plugin'ом из gpu-operator
> (classic-vLLM на nvidia.com/gpu + DRA-claim 4Gi на одной RTX 4090
> одновременно, CDI-инжекция работает).
>
> Ключевые правила DRA (k8s 1.36, драйвер gpu.nvidia.com) — в комментариях
> manifests/resourceclaim-templates.yaml: CEL-синтаксис, ключи capacity,
> порог 24ГБ≠24Gi, обязательность явного capacity на расшаренной карте.
>
> Оставшийся ниже текст — архивы экспериментов: DRA поверх MKS-стека и
> gpu-operator в GPUCluster-режиме (рабочий, заменён совмещением со
> standalone-чартом ради classic-пути в production).

---

# Протокол эксперимента (архив)

Проверяем, работает ли DRA поверх предустановленного Selectel-стека GPU
(device plugin + драйверы в образе нод). Мотивация: DRA даёт scheduling
по атрибутам устройств (в т.ч. память GPU) вместо лейблов пулов `gpu:`.

**Статус эксперимента.** Не является поддерживаемым путём Selectel:
драйвер DRA ставится поверх управляемого образа (инвариант №6 AGENTS.md
про GPU Operator — здесь тот же принцип: стек GPU на нодах от Selectel).
Обратно откатывается полностью (см. «Откат»).

## Результат (проверено на живом кластере, ru-6, RTX 4090)

**DRA на MKS работает.** Оба теста пройдены: под с ResourceClaim получил GPU
на существующей ноде и на поднятой Karpenter'ом. Рецепт ниже — воспроизведённая
рабочая конфигурация. Ключевые находки:

- Чарт **25.3.2** (не новее): v25.12.0 собран под NVML ≥ 580 (падение
  `undefined symbol: nvmlDeviceGetAddressingMode`), а на MKS-нодах драйвер
  575.57.8. Версию поднимайте только после обновления драйвера в образах MKS.
- Чарт отказывается ставить GPU-плагин рядом со стандартным device plugin
  (защита от двойной аллокации) → device plugin отключаем (шаг 3), а флагом
  `gpuResourcesEnabledOverride=true` подтверждаем осознанность.
- Зеркала Selectel (nvcr-registry/docker-registry.selectel.ru) флапают 500-ми
  на прогреве кеша — при ImagePullBackOff просто ретраить/пересоздать под.
- Реальное значение `instance-gpu-name` для RTX 4090 (обеих, 24 и 48 ГБ) —
  `RTX4090` (без пробелов); различить 24/48 ГБ только по флейвору (GL10 и т.п.).

## Что уже проверено на кластере (v1.36.2, ru-6)

- kube-apiserver: группа `resource.k8s.io` подаётся, включая **v1** (GA-версию API).
- kubelet (configz GPU-ноды): кастомных `featureGates` нет — работают дефолты 1.36,
  DRA-аллокация и CDI работают (подproof: smoke-тесты ниже).
- Лейбл GPU-нод MKS: `nvidia.com/gpu: "true"` (лейбла `nvidia.com/gpu.present`,
  на который рассчитывают дефолты чарта, на MKS-нодах НЕТ — см. шаг 2).

## Фича-гейты: какие и когда включены

DRA требует два гейта:

| Гейт | Где нужен | Появился |
|---|---|---|
| `DynamicResourceAllocation` | kube-apiserver, kube-controller-manager, kubelet | 1.26 |
| `DRAControlPlaneController` | kube-scheduler, kube-controller-manager | 1.32 |

Дефолты по версиям (по памяти, живую таблицу не сверял — статус «вероятно»):

- 1.26–1.33 — alpha, выключен по умолчанию;
- 1.34 — beta, включён по умолчанию;
- 1.35+ — GA-трек (на 1.36.2 API v1 подаётся — похоже на GA).

Включение в кластере MKS (terraform, `selectel_mks_cluster_v1`):
https://docs.selectel.ru/terraform/selectel-provider-reference/resources/mks_cluster_v1/

```hcl
feature_gates = ["DynamicResourceAllocation", "DRAControlPlaneController"]
```

На кластерах 1.34+ это, скорее всего, не нужно. Изменение `feature_gates`
может потребовать обновления кластера/нод — не проверено.

## Шаги

1. **(только k8s ≤ 1.33)** добавить `feature_gates` в `selectel_mks_cluster_v1`
   и применить terraform.

2. **Установить драйвер NVIDIA DRA** — helm-чарт с NGC, **версия 25.3.2**:
   новее нельзя (см. «Результат»), старее не проверялось.

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update

   # Патчи под MKS (дефолты чарта рассчитаны на NFD/GFD-лейблы и control-plane
   # ноды, которых в управляемом MKS нет):
   #   kubeletPlugin.affinity=null — убрать NFD-условия (pci-10de / gpu.present);
   #   kubeletPlugin.nodeSelector — MKS-лейбл GPU-нод nvidia.com/gpu=true
   #     (--set-string: иначе helm отдаст bool, а не строку!);
   #   controller.affinity=null — убрать пин на control-plane (в MKS их нет);
   #   controller.nodeSelector — системные CPU-ноды (лейбл workload=cpu из 01-cluster);
   #   gpuResourcesEnabledOverride=true — подтверждение «device plugin отключён» (шаг 3).
   helm upgrade --install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
     --version="25.3.2" \
     --namespace nvidia-dra-driver-gpu --create-namespace \
     --set gpuResourcesEnabledOverride=true \
     --set kubeletPlugin.affinity=null \
     --set-string 'kubeletPlugin.nodeSelector.nvidia\.com/gpu=true' \
     --set controller.affinity=null \
     --set-string 'controller.nodeSelector.workload=cpu'
   ```

3. **Отключить стандартный device plugin** — иначе двойная аллокация GPU
   (чарт это прямо запрещает — см. шаг 2). Это скрытая зависимость теста:
   все classic-поды с `nvidia.com/gpu` (включая vLLM) перестанут планироваться.

   ```bash
   kubectl -n kube-system get ds nvidia-device-plugin-daemonset -o yaml > /tmp/nvidia-device-plugin-backup.yaml
   kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type=merge \
     -p '{"spec":{"template":{"spec":{"nodeSelector":{"dra-test-disabled":"true"}}}}}'
   ```

   Проверено: MKS не возвращает DS обратно (mks.operational-лейбл не мешает патчу).
   Риск: нода, созданная Karpenter'ом после этого, вернёт DS-под (патч — на шаблон DS,
   пересоздание ноды не влияет).

4. **Срезы устройств** (появляются ~за минуту):

   ```bash
   kubectl get resourceslices
   kubectl get deviceclasses   # должен быть gpu.nvidia.com
   ```

5. **Свободная нода**: остановить vLLM smoke (если запущен — GPU занят):

   ```bash
   kubectl scale deploy deepseek-r1-distill-llama-8b --replicas=0
   ```

6. **Тест 1 — kubelet + драйвер** (пин на существующую GPU-ноду):
   `kubectl apply -f resourceclaim-template.yaml smoke-pinned.yaml`,
   затем `kubectl logs dra-smoke-pinned` — вывод `nvidia-smi`.

7. **Тест 2 — Karpenter** (под без пина): `kubectl apply -f smoke-provision.yaml`.
   Если GPU-нода уже есть — под сядет на неё; чистый тест — удалить nodeclaim
   (именно nodeclaim, не Node: `kubectl delete nodeclaim <имя>`) и применить под заново.

## Интерпретация

| Результат | Вывод |
|---|---|
| CrashLoopBackOff `undefined symbol: nvmlDeviceGetAddressingMode` | версия драйвера DRA требует NVML новее нодовой — откат на 25.3.2 |
| resourceslices пусто | kubelet-гейт выключен в образе MKS; включить `feature_gates` и пересоздать ноды |
| тест 1 ок, тест 2 висит в Pending | Karpenter не умеет поды с ResourceClaims — остаёмся на лейблах `gpu:` |
| оба ок | DRA работает; можно планировать миграцию инференса на ResourceClaim с атрибутами (память GPU вместо лейблов) |

**Подтверждено проверкой:** последний вариант. При сосуществовании с device plugin
оба механизма видят одни и те же GPU без координации (чарт это запрещает) —
классические `nvidia.com/gpu`-поды и DRA-поды не смешивать на одних нодах.

## Откат

```bash
kubectl delete -f smoke-provision.yaml smoke-pinned.yaml resourceclaim-template.yaml
helm uninstall -n nvidia-dra-driver-gpu nvidia-dra-driver-gpu
# вернуть device plugin (патч из шага 3 скрыл его под несуществующий лейбл)
kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"mks.operational/software":"nvidia-device-plugin","nvidia.com/gpu":"true"}}}}}'
kubectl scale deploy deepseek-r1-distill-llama-8b --replicas=1
# (если включали) убрать feature_gates из terraform и применить
```
