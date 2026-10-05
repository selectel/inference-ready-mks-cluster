# 06 — Заметки по платформе Selectel MKS (для деплоя AIBrix + vLLM)

**Источники:** только официальная документация Selectel ([docs.selectel.ru](https://docs.selectel.ru/), EN-версии по `/en/`; русские зеркала — те же пути без `/en`).

---

## 1. Поддерживаемые версии Kubernetes

- MKS поддерживает **Kubernetes 1.34.x, 1.35.x, 1.36.x** — [Описание продукта](https://docs.selectel.ru/managed-kubernetes/about/about-managed-kubernetes/).
- Ротация версий — по [release notes](https://docs.selectel.ru/managed-kubernetes/release-notes/) (1.36 добавлена / 1.33 удалена и т. д.).
- Апгрейд минорной версии — **ручной** (панель → Settings; сначала masters, потом workers; 30 мин – 12 ч; неостанавливаемый) — [Update Kubernetes version](https://docs.selectel.ru/managed-kubernetes/clusters/upgrade-version/).
- Автообновление патчей — опционально; включено по умолчанию для **regional**-кластеров, выключено для **zonal** (недоступно для basic-кластеров с 1 master).
- Типы кластеров: **fault-tolerant multi-zonal** (3 masters в разных сегментах мультизонального пула, SLA 99.98%), **fault-tolerant** (3 masters, однозональный пул), **basic** (1 master, без SLA). Неизменяемо после создания.

> Для AIBrix это значит: любой поддерживаемый вариант (AIBrix заявляет совместимость с vanilla Kubernetes; проверьте требуемую минорную версию в [документации установки AIBrix](https://aibrix.readthedocs.io/latest/getting_started/installation/installation.html) на момент деплоя).

## 2. Нодгруппы и GPU

- Типы нодгрупп: **cloud-серверы** (кастомные конфиги; фиксированные GPU-конфиги; фиксированные flavor'ы через API/Terraform) и **dedicated-серверы**; смешивать в одном кластере нельзя.
- **GPU в фиксированных конфигурациях MKS** ([список](https://docs.selectel.ru/managed-kubernetes/create/create-cloud-gpu-cluster/#available-gpu)):

| GPU | VRAM | Диапазон конфигураций (GPU / vCPU / RAM) |
|---|---|---|
| NVIDIA H100 | 80 GB HBM3 | 1–2 / 12–48 / 128–256 GB |
| NVIDIA H200 | 141 GB HBM3e | 1–8 / 12–192 / 120 GB–1 TB |
| NVIDIA A100 40Gb | 40 GB | 1–8 / 6–48 / 87–704 GB |
| NVIDIA A100 80Gb | 80 GB | 1–8 / 12–192 / 128 GB–1 TB |
| NVIDIA L4 | 24 GB | 1–8 / 8–128 / 32–512 GB |
| NVIDIA RTX 6000 Ada («аналог L40» по докам) | 48 GB | 1–4 / 12–96 / 64–450 GB |
| NVIDIA RTX 6000 Pro (Blackwell) | 96 GB GDDR7 | 1–8 / 16–256 / 120 GB–1 TB |
| NVIDIA RTX 4090 24/48 GB | 24/48 GB | 1–4 / 1–8 соответственно |
| Tesla T4 / A30 / A2 / A2000 / A5000 / GTX 1080 / RTX 2080 Ti | 6–24 GB | различные |

  **L40S под этим именем в списке нет** — ближайшая документированная карта: RTX 6000 Ada.
- **Региональная доступность GPU** ([матрица](https://docs.selectel.ru/infrastructure/infrastructure-matrix/), секция GPU): H100 — Москва, пул **ru-7b**; H200 — ru-6a/6b/6c и ru-7b; A100 40Gb — ru-7a и ru-9a (СПб); A100 80Gb — ru-7b; L4 — ru-6a, ru-7a; RTX 4090 48GB — ru-6a. Новосибирск (ru-8) — без GPU. Актуальную разбивку смотреть в матрице.
- **Драйверы GPU + NVIDIA device plugin предустановлены по умолчанию** (тумблер GPU Drivers включён при создании кластера/нодгруппы). Terraform: `install_nvidia_device_plugin` — «Enables or disables installation of the NVIDIA Device Plugin and GPU drivers» ([mks_nodegroup_v1](https://docs.selectel.ru/terraform/selectel-provider-reference/resources/mks_nodegroup_v1/)).
- Модули ядра предустановленных драйверов: **open** для архитектур Turing и новее; **proprietary** только для GTX 1080 (Pascal) — [GPU drivers](https://docs.selectel.ru/managed-kubernetes/node-groups/gpu-drivers/).
- Если тумблер выключить — драйверы ставятся самостоятельно через **NVIDIA GPU Operator** (официальная инструкция с `helm.ngc.nvidia.com`), но: **для GPU-нодгрупп без предустановленных драйверов кластерный автоскейлинг недоступен**.
- Хард-лимиты ([лимиты](https://docs.selectel.ru/managed-kubernetes/about/about-managed-kubernetes/)): **15 нод на нодгруппу**, 100 нодгрупп на пул, 32 vCPU / 256 GB RAM на ноду (больше — через фиксированные flavor'ы), boot-диск ≤ 1.2 TB, **100 подов на ноду**, 256 PV на ноду, минимальный PV 1 GB.
- Нодгруппы поддерживают **лейблы, taинты (NoSchedule/PreferNoSchedule/NoExecute), user-data (≤ 47 KB)** и **preemptible (spot) группы** — удобно изолировать GPU-ноды таинтами под AIBrix/vLLM.

## 3. Автоскейлинг (кратко)

Подробный разбор совместимости с AIBrix — в [03-autoscaling.md](03-autoscaling.md). Ключевое:

- **Cluster Autoscaler** устанавливается автоматически; включается per-нодгруппа с min/max. Анализирует запросы vCPU/RAM/**GPU**, скан каждые 10 с.
- Тонкая настройка — ConfigMap `cluster-autoscaler-nodegroup-options` в `kube-system` (`scaleDownUtilizationThreshold`, `scaleDownGpuUtilizationThreshold`, `scaleDownUnneededTime`, `zeroOrMaxNodeScaling`, `maxNodeProvisionTime` и др.).
- Альтернатива — **Karpenter** (самостоятельная установка, `oci://ghcr.io/selectel/mks-charts/karpenter`); одновременно с CA использовать нельзя.
- **GPU-нодгруппы с предустановленными драйверами масштабируются**; без драйверов / на dedicated — нет.
- **Metrics Server предустановлен** (MKS ≥1.27) — на нём работают HPA/VPA.

## 4. Сеть

- **CNI: Calico (дефолт) или Cilium**, выбирается при создании кластера, потом не меняется. У Cilium по умолчанию: `envoy daemonset` включён, `hubble-relay` выключен (меняется только через MKS API; hubble-relay требует ноды ≥4 GB RAM).
- **Service type=LoadBalancer** реализуется балансировщиками облачной платформы (видны в панели: Cloud Servers → Load Balancers). Настройка — через **OpenStack-LB аннотации** ([документация](https://docs.selectel.ru/managed-kubernetes/networks/loadbalancing-with-ingress/load-balancers/)):
  - дефолт: **публичный floating IP**, тип «Basic with redundancy» (меняется через `loadbalancer.openstack.org/flavor-id`);
  - внутренний LB: `service.beta.kubernetes.io/openstack-internal-load-balancer: "true"`;
  - LB в другой подсети: `loadbalancer.openstack.org/subnet-id` + `loadBalancerIP`;
  - сохранить floating IP при пересоздании: `loadbalancer.openstack.org/keep-floatingip: "true"`;
  - таймауты/лимиты: `connection-limit`, `timeout-client-data` (50000 ms), `timeout-member-connect` (5000 ms), `timeout-member-data` (50000 ms), `enable-health-monitor`;
  - сохранение клиентского IP: `x-forwarded-for` или `proxy-protocol`.
  - В доках имя «Octavia» не упоминается, но неймспейс аннотаций и flavor/subnet-UUID однозначно указывают на OpenStack LBaaS (Octavia).
- **Ingress-контроллер не предустановлен.** Документированный пример — Traefik. **Приложение NGINX Ingress Controller деприкейтед**: «Support discontinued… we recommend switching to Gateway API, e.g. Envoy Gateway» ([Applications](https://docs.selectel.ru/managed-kubernetes/clusters/applications/)).
- **Gateway API / Envoy Gateway официально поддерживается без ограничений**: установка из панели (вкладка Applications) или Helm (`oci://docker.io/envoyproxy/gateway-helm --version v1.6.3`); задокументированы GatewayClass/Gateway/HTTPRoute/GRPCRoute, настройка LB, TLS-терминация, миграция с Ingress — [Traffic Balancing with Gateway API](https://docs.selectel.ru/managed-kubernetes/networks/loadbalancing-with-envoy-gateway/). Установка из панели создаёт LB Basic-with-redundancy + floating IP (неизменяемо; для кастомных параметров LB — Helm).

  > Это напрямую релевантно AIBrix: его gateway построен на **Envoy Gateway** — путь, который Selectel официально рекомендует. Совпадение «интересов» полное.
- **Kube API**: публичный по умолчанию; опция **Private kube API** при создании (доступ только из приватной сети; потом не меняется).
- **Сетевая модель нод**: все ноды в **приватной подсети**; при создании автоматически создаются `<cluster_name>-network`, подсеть и `<cluster_name>-router`. Кастомная подсеть должна: принадлежать сети проекта, быть подключена к **cloud-роутеру**, не пересекаться с **10.10.0.0/16, 10.96.0.0/12, 10.250.0.0/16, 10.251.0.0/24** (зарезервировано под внутреннюю адресацию MKS), DHCP выключен, только default security group (правила менять нельзя).
- DNS: гайды по [кастомизации CoreDNS](https://docs.selectel.ru/managed-kubernetes/networks/customize-coredns/) и [NodeLocal DNS Cache](https://docs.selectel.ru/managed-kubernetes/networks/configure-node-local-dns/) — актуально для pull'а моделей с HuggingFace (DNS-интенсивная операция).
- Часть TCP/UDP-портов блокируется на уровне инфраструктуры — [заблокированные порты](https://docs.selectel.ru/infrastructure/blocked-ports/).

## 5. Хранилище

- **CSI-драйвер: `cinder.csi.openstack.org`** (OpenStack Cinder CSI) для сетевых томов — [Persistent volumes](https://docs.selectel.ru/managed-kubernetes/volumes/persistent-volumes/). PV на локальных дисках — только с ручной установкой CSI, данные теряются при удалении ноды.
- **StorageClass по умолчанию** (быстрый сетевой том) создаётся автоматически для сегментов пулов, где лежат нодгруппы.
- Формат `type` в StorageClass: `<volume_type>.<location>`, где типы — **basic (HDD Basic), basicssd (SSD Basic), universal (SSD Universal), universal2 (SSD Universal v2), fast (SSD Fast), fast2 (SSD Fast v2)**; локация — пул или сегмент (например `fast.ru-1a`). Готовые манифесты: [selectel/kubernetes-examples](https://github.com/selectel/kubernetes-examples/tree/master/storageclasses).
- Блочные тома — **только ReadWriteOnce**. Для RWX — подключить [файловое хранилище (NFS)](https://docs.selectel.ru/file-storage/add/add-storage-to-managed-kubernetes-cluster-in-one-pool/) к нодам кластера.
- Расширение томов поддерживается (`allowVolumeExpansion: true`). **Topology-Aware Provisioning недоступен.**
- Особенность: `securityContext.fsGroup` не применяется к PV, если в StorageClass не задан `fsType: ext4`.
- Снапшоты томов поддерживаются.
- Зоны доступности = сегменты пулов (ru-1a/1b/1c); нодгруппы могут занимать сегменты одного пула; существуют мультизональные пулы (ru-6).

## 6. Ограничения, значимые для операторов/CRD/privileged/egress

- **Ограничений на установку CRD/операторов не задокументировано** — наоборот, NVIDIA GPU Operator, Karpenter, Traefik и Envoy Gateway официально документированы как user-installed.
- **Admission controllers и feature gates настраиваются пользователем** (страницы доков + API MKS: Get supported admission controllers / feature gates).
- **Egress / pull из публичных registry**: официальные инструкции MKS сами тянут из `docker.io` (чарт Envoy Gateway, образцы NVIDIA), `traefik.github.io`, `helm.ngc.nvidia.com`. Интернет-egress нод — через **cloud-роутер, подключённый к интернету** (1:1 NAT через внешний IP роутера); официальные Terraform-примеры MKS строят именно такую топологию.
- Операционные лимиты, влияющие на vLLM/AIBrix: **100 подов на ноду**, 15 нод на нодгруппу (нужно больше GPU-нод — создавайте несколько GPU-групп), 256 PV на ноду, boot-диск очищается при переустановке ноды (минорные апгрейды, патчи, авто-recovery).
- Юридическая граница использования — [Conditions of Use (PDF)](https://files.selectel.ru/docs/ru/conditions-kubernetes-cluster.pdf).

## 7. Мирринг образов

- Pull-through-зеркало **`docker-registry.selectel.ru`** (используется в манифестах этого репозитория: образы vLLM и утилит в `addons/models/`, `addons/openwebui/`); в доках Selectel отдельно не описано — проверено практикой.
- Образы AIBrix живут на `ghcr.io` (vllm-project/aibrix) и `docker.io` (redis, jaeger, otel). Egress на `docker.io` подтверждён официальными инструкциями; **egress на `ghcr.io` в доках явно не упомянут — проверьте из пода на тестовом кластере** (установка AIBrix из `addons/aibrix/chart/` прошла успешно — egress был).
- Управляемый Container Registry Selectel и его интеграция с MKS здесь не используется (образы — через зеркало и прямые репозитории).

## Не подтверждено (явные пробелы)

Не выносить во внутренние доки как факты:

1. **MTU** для Calico/Cilium-оверлеев в MKS — не документирован. Проверить эмпирически/через поддержку.
2. **Поддержка NetworkPolicy** — явного утверждения в доках MKS нет (Calico/Cilium — полноценные CNI, но официальной фразы нет).
3. **Privileged-поды / hostNetwork / hostPath / дефолты Pod Security Admission** — ограничений не задокументировано; проверить на тестовом кластере.
4. **Подключён ли автоматически созданный `<cluster_name>-router` к интернету по умолчанию** — прямо не указано (все официальные сценарии подразумевают работающий egress «из коробки»); проверить внешний gateway роутера в панели.
5. **Egress на `ghcr.io` и `huggingface.co`** — `docker.io`/`traefik.github.io`/`helm.ngc.nvidia.com` подтверждены инструкциями; ghcr.io/HF — нет. Проверить из пода (образы AIBrix — на ghcr.io; модели — на huggingface.co).
6. **L40S по имени** — в списке GPU отсутствует; ближайшее — RTX 6000 Ada («L40 equivalent»).
7. **CRaaS pull-through cache** — не документирована; мирринг только ручной.
8. **«Octavia» как имя LB-реализации** — в доках называется «балансировщики облачной платформы» с OpenStack-аннотациями.

## Quick reference для адаптации values/манифестов AIBrix

- Базовые версии: **K8s 1.34–1.36**, containerd, CNI Calico (дефолт).
- GPU: драйверы + device plugin **предустановлены** → поды vLLM могут сразу запрашивать `nvidia.com/gpu`. Максимум GPU в ноде: H100 — **2**, H200/A100-80/RTX 6000 Pro — до **8**.
- Размерность: ≤15 нод на группу; spot-группы доступны (СПб/МСК/НСК); лейблы/таинты поддерживаются → изолируйте GPU-ноды таинтами под AIBrix.
- Ingress: ставится самостоятельно; **Envoy Gateway — официально рекомендованный путь** (чарт v1.6.3) — идеально совпадает с зависимостью AIBrix.
- LB-аннотации: `loadbalancer.openstack.org/*` (flavor-id, subnet-id, keep-floatingip, таймауты, proxy-protocol).
- Storage: Cinder CSI, дефолтный fast StorageClass, только RWO (RWX — NFS File Storage), расширение томов поддерживается, `fsType: ext4` для fsGroup.
- Registry: pull-through-зеркало `docker-registry.selectel.ru` (практика этого репо; в доках не описано).
- Egress — через интернет-подключённый cloud-роутер (1:1 NAT); зарезервированные CIDR: `10.10.0.0/16`, `10.96.0.0/12`, `10.250.0.0/16`, `10.251.0.0/24` (не пересекать с вашей сетью).
