# GPU Operator (classic-режим: device plugin)

NVIDIA GPU Operator в **classic-конфигурации**: ставит на GPU-нодах драйвер,
container-toolkit, **device plugin** (`nvidia.com/gpu`) и DCGM-exporter.
Аллокация GPU — стандартная (`nvidia.com/gpu`), Karpenter провижинит ноды
под такие поды нативно. Это production-путь.

DRA (запросы по памяти GPU, ResourceClaims) — отдельный тестовый сценарий:
см. `addons/dra-test/` (там же, почему DRA пока не production: Karpenter
без поддержки DynamicResources не провижинит ноды под DRA-поды).

Проверено на живом кластере: Selectel MKS v1.36.2, ru-6, RTX 4090 (GL10),
karpenter (кастомная сборка), 2026-09-10. Статус: classic-стек работает
end-to-end; DRA-режим (GPUCluster) проверен до этого в тот же день.

## Состав

```
chart/                          vendored чарт gpu-operator v26.7.0 (GitHub-тег;
                                из NGC helm-репо не тянется — флапает 403).
                                Зависимость node-feature-discovery 0.19.0 —
                                в chart/charts/ (уже собрана, helm dep build не нужен).
helm/values-selectel-mks.yaml   classic-конфигурация (см. комментарии внутри).
```

## Предусловия

1. **SelectelNodeClass**: `installNvidiaDevicePlugin: false`
   (addons/karpenter/selectelnodeclass.yaml) — ноды Karpenter создаёт без
   MKS-стека (без device plugin и драйверов). Их ставит этот оператор.
   ⚠ Поле поддерживается ТОЛЬКО кастомной сборкой karpenter: публичный чарт
   `mks-charts/karpenter 0.3.1` его не знает — его контроллер стирает поле
   из NodeClass (проверено 2026-09-10).

## Как это работает

1. Нода поднимается Karpenter'ом без GPU-стека.
2. NFD (в составе чарта) размечает ноду по PCI-ID 10de → оператор ставит
   `nvidia.com/gpu.present=true` + `nvidia.com/gpu.deploy.*`.
3. Оператор ставит драйвер (NVIDIADriver CR, компиляция под ядро ~2 мин,
   Ubuntu 24.04 / kernel 6.8), toolkit, device plugin, DCGM-exporter.
4. Появляется allocatable `nvidia.com/gpu`; поды с requests/limits
   `nvidia.com/gpu` планируются штатно (kube-scheduler + device manager).

## Установка

```bash
# вариант 1: terraform (корень infra/02-addons, тумблер install_gpu_operator)
terraform -chdir=infra/02-addons apply -var-file=../../blueprint.tfvars

# вариант 2: руками из чарта в репо
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
helm upgrade --install gpu-operator addons/gpu-operator/chart \
  -n gpu-operator --create-namespace \
  -f addons/gpu-operator/helm/values-selectel-mks.yaml --wait
```

CRD при helm upgrade не обновляются — при смене мажорной версии чарта
дополнительно: `kubectl apply -f addons/gpu-operator/chart/crds/`.

## Переключение режима DRA ⇄ classic

Чарт жёстко запрещает ClusterPolicy и GPUCluster одновременно (валидация:
«only one CR can exist»). При переключении gpuCluster→clusterPolicy через
helm upgrade GPUCluster CR **остаётся** (annotation `helm.sh/resource-policy:
keep`, cleanup-hook срабатывает только при uninstall) — удалить вручную:

```bash
kubectl delete gpucluster gpu-cluster   # оператор дренирует DRA-поды через finalizer
```

DRA-драйвер при этом можно оставить — отдельным чартом addons/dra-test/
(сосуществует с device plugin через gpuResourcesEnabledOverride; проверено
2026-09-10: classic-vLLM nvidia.com/gpu + DRA-claim 4Gi на одной карте).

## Проверка состояния

```bash
kubectl -n gpu-operator get pods                     # стек на GPU-нодах
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

## Грабли (пойманы на живом кластере)

- ⚠ **ТОЛЬКО NRI-режим совместим с MKS** (уже включён в values —
  `cdi.nriPluginEnabled: true`). Без NPI (дефолт чарта) toolkit пишет
  drop-in в /etc/containerd и шлёт containerd SIGHUP — на MKS-нодах
  (containerd 2.3.3) containerd после этого не восстанавливается и нода
  умирает («Kubelet stopped posting node status»), проверено дважды,
  детерминированно (2026-09-10). В NPI-режиме — noop-конфигуратор:
  конфиг containerd не читается и не изменяется, рестарта нет; инжекция
  устройств через NPI-плагин (containerd 2.x — NPI включён по умолчанию).
- **Переключение gpuCluster→clusterPolicy**: GPUCluster CR остаётся после
  upgrade (resource-policy keep) — удалить вручную
  `kubectl delete gpucluster gpu-cluster` (оператор дренирует DRA-поды
  через finalizer).
- **Зеркало nvcr** (`nvcr-registry.selectel.ru`) флапает 500-ми при прогреве
  кеша (в т.ч. на отдельных блобах). Лечение: пересоздать под / ретраить.
  Часть образов быстрее тянется с `docker-registry.selectel.ru/nvidia/...`.
- **Вторая реплика karpenter** может висеть в ImagePullBackOff на GPU-нодах:
  registry `local-registry:5000` резолвится не из всех сетей — держите
  кастомный karpenter на CPU-нодах или выкладывайте образ в доступный registry.
- **Дренаж удаляемой ноды может закольцеваться**: DS-контроллеры
  пересоздают поды на удаляемой ноде быстрее, чем karpenter их дренирует
  («Failed to drain node»). Лечение: снять с ноды лейблы селекции
  (nvidia.com/gpu.deploy.*, pci-10de) — `kubectl label node <имя> <k>...-`.

## Обновление vendored чарта (например v26.7.0 → v26.8.0)

```bash
git clone --depth 1 --branch v26.8.0 https://github.com/NVIDIA/gpu-operator.git /tmp/gpu-operator-repo
rm -rf addons/gpu-operator/chart && cp -r /tmp/gpu-operator-repo/deployments/gpu-operator addons/gpu-operator/chart
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null # только для helm dep build
helm dependency build addons/gpu-operator/chart  # пересобрать charts/*.tgz
```
Затем вручную: обновить версии в этом README, в helm/values-selectel-mks.yaml
(`operator.version`, `validator.version`, `driver.version`) и в списке пинов
AGENTS.md; проверить рендер (флаг `--api-versions resource.k8s.io/v1/DeviceClass`
нужен только в DRA-режиме); применить CRD вручную
(`kubectl apply -f chart/crds/`).

## Откат

```bash
terraform -chdir=infra/02-addons apply -var-file=../../blueprint.tfvars \
  -var install_gpu_operator=false
# или: helm uninstall -n gpu-operator gpu-operator
# NodeClass: убрать installNvidiaDevicePlugin: false и применить — ноды
# заменятся на стандартные с MKS-стеком (драйверы+device plugin от Selectel).
```
