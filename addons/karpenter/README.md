# Karpenter на Selectel MKS

NodeClass + NodePool'ы для GPU-инференса. Применяются после установки Karpenter
(корень `infra/02-addons`, тумблер `install_karpenter = true`):

```bash
export KUBECONFIG=<kubeconfig из 01-cluster>
kubectl apply -f addons/karpenter/selectelnodeclass.yaml

# пулы разложены по регионам — применяйте из директории своего региона
# (полный список — ls addons/karpenter/ru-6/ или ls addons/karpenter/ru-7/):
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-h200.yaml
kubectl apply -f addons/karpenter/ru-6/nodepool-gpu-rtx6000-pro.yaml
# ... и т.д. по нужным GPU
```

Karpenter создаёт ноды, когда появляются Pending-поды с запросом `nvidia.com/gpu`.
Гибкость подбора — в `requirements` (полный список ключей — в документации
[karpenter-provider-selectel](https://github.com/selectel/karpenter-provider-selectel-docs)):
`instance-gpu-name`, `instance-gpu-count`, `instance-family`, `instance-cpu/memory`,
`capacity-type` (on-demand/spot), `instance-local-disk`.

## Матрица доступности GPU по зонам

NodePool'ы разложены по директориям регионов — `ru-6/` и `ru-7/`; в каждом
файле — только зоны своего региона. Кластер MKS живёт в одном пуле, поэтому
применяйте пулы из директории региона кластера. GPU, доступный в обоих регионах,
лежит в обеих директориях отдельными файлами со своими зонами.
Кластер поднимается в пуле, который указан в `region` корня `01-cluster`.

Квота ускорителей по умолчанию — **32 GPU на зону** (по данным Selectel на момент
написания; проверьте актуальность в панели).

| GPU | VRAM | Пул | ru-6a | ru-6b | ru-6c | ru-7a | ru-7b |
|---|---|---|---|---|---|---|---|
| A2000 | 6 GB | `gpu-a2000` | | | | ✓ | ✓ |
| GTX 1080 | 8 GB | `gpu-gtx1080` | | | | ✓ | |
| RTX 2080 Ti | 11 GB | `gpu-rtx2080ti` | | | | | ✓ |
| A2 | 16 GB | `gpu-a2` | | | | ✓ | |
| Tesla T4 | 16 GB | `gpu-t4` | | | | ✓ | |
| L4 | 24 GB | `gpu-l4` | ✓ | | | ✓ | |
| A30 | 24 GB | `gpu-a30` | | | | ✓ | |
| A5000 | 24 GB | `gpu-a5000` | ✓ | | | ✓ | ✓ |
| RTX 4090 24 GB | 24 GB | `gpu-rtx4090-24` | ✓ | | | | ✓ |
| A100 40 GB | 40 GB | `gpu-a100-40` | | | | ✓ | |
| RTX 4090 48 GB | 48 GB | `gpu-rtx4090-48` | ✓ | | | | |
| RTX 6000 Ada | 48 GB | `gpu-rtx6000-ada` | | | | | ✓ |
| A100 80 GB | 80 GB | `gpu-a100-80` | | | | | ✓ |
| H100 | 80 GB | `gpu-h100` | | | | | ✓ |
| RTX 6000 Pro | 96 GB | `gpu-rtx6000-pro` | ✓ | ✓ | ✓ | ✓ | ✓ |
| H200 | 141 GB | `gpu-h200` | ✓ | ✓ | ✓ | | ✓ |

## Выбор пула под модель (эвристика по VRAM)

| VRAM | Модели |
|---|---|
| 6–16 GB | 1–4B quant, dev/test |
| 24 GB | 1–8B bf16, LoRA-ферма |
| 40–48 GB | 8–32B (bf16/quant), быстрые 7–14B |
| 80–96 GB | 32–70B, высокий RPS |
| 141 GB | 70B+ bf16, максимальный контекст |

Значения `instance-gpu-name` — это label Kubernetes (без пробелов). Однословные
значения (`L4`, `A100`, `H100`, `A2000`…) совпадают с маркетинговыми именами;
для составных имён (`RTX 6000 Pro` и т.п.) в пулах перечислены варианты
написания — несовпавший вариант безвреден (не матчится).
Окончательная проверка: после первой поднятой ноды выполните
`kubectl describe node | grep instance-gpu-name` и оставьте в `values` совпавший вариант.

## Как поды попадают на нужный пул

`weight` — приоритет пулов (больше = предпочтительнее). Веса инвертированы по VRAM:
**под без селектора получает самый дешёвый подходящий пул** (дешевле = выше вес).
Karpenter не знает VRAM — под с запросом `nvidia.com/gpu: 1` подходит любому пулу,
поэтому без селектора выбор определяется только weight.
Точный выбор пула для модели — селекторы в манифесте:
`nodeSelector: {gpu: a100-40}` или `nodeAffinity` по лейблу `gpu`.
Для устойчивости к зонам берите affinity со списком пулов
(`key: gpu, operator: In, values: [l4, a5000, rtx4090-24]`) —
одиночный nodeSelector оставляет под Pending, если GPU нет в зоне.
Пулы не тейнтятся намеренно — сэмплы из `aibrix/manifests` не содержат tolerations.
Для production добавьте taint `nvidia.com/gpu=true:NoSchedule` в NodePool
и tolerations в Deployment'ы моделей.

## Доступность типов диска (universal / universal2)

Источник: [docs.selectel.ru — сетевые диски](https://docs.selectel.ru/cloud/servers/volumes/about-network-volumes/).
В ru-6 типа `universal` нет — если NodePool смотрит в ru-6a, нода с диском
`universal` не создаётся. Используйте `universal2` (есть во всех GPU-зонах).

| Сегмент | universal | universal2 |
|---|---|---|
| ru-1a, ru-1b, ru-1c | да | нет |
| ru-2a | да | нет |
| ru-2b | да | нет |
| ru-2c | да | да |
| ru-3a | да | нет |
| ru-3b | да | да |
| ru-6a, ru-6b, ru-6c | **нет** | да |
| ru-7a, ru-7b | да | да |
| ru-8a | да | да |
| ru-9a | да | да |

Ещё в ru-6 нет типа `fast` — вместо него там `fast2`.

## Важно

- Автоскейлинг и автовосстановление нодгрупп MKS должны быть выключены
  (в `01-cluster` уже так) — Karpenter единственный менеджер нод.
- Karpenter управляет только нодами, которые создал сам.
- Обновление CRD Karpenter при `helm upgrade` — вручную
  (CRD из `crds/` чарта применяются только при первом install).
