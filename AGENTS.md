# AGENTS.md

Правила для ИИ-агентов (и людей), вносящих изменения в этот репозиторий.

## Что это за репозиторий

Blueprint для LLM-инференса на Selectel Managed Kubernetes: Terraform
поднимает проект, сеть, кластер MKS и ставит
Karpenter + AIBrix + Envoy Gateway. Язык репозитория — **русский** (доки,
комментарии, коммит-сообщения можно английские).

## Структура

```
infra/01-cluster/   Terraform: проект, service-пользователь, сеть, кластер MKS,
                    CPU-нодгруппа, kubeconfig. Облачный слой — БЕЗ аддонов.
                    Опционально dns.tf: зона DNS + dns-пользователь
                    (create_zone_and_user=true; alias-провайдер selectel.dns
                    с auth_region=ru-1 — в ru-6 нет dnsv2-endpoint в каталоге).
infra/02-addons/    Terraform: helm-установка karpenter / envoy-gateway / aibrix,
                    тумблерами install_* в tfvars. Подключается по kubeconfig
                    из 01-cluster (два корня — обязательно, см. инварианты).
blueprint.tfvars.example
                    ЕДИНЫЙ файл значений для обоих корней (в корне репо):
                    клиент копирует в blueprint.tfvars и передаёт в apply
                    флагом -var-file=../../blueprint.tfvars (лишние для
                    корня переменные terraform игнорирует — Warning)
addons/aibrix/      AIBrix: vendored-чарт (chart/), values, manifests/, docs/
addons/litellm/     LiteLLM Proxy: vendored-чарт (chart/), values — auth-слой
                    (virtual keys) перед AIBrix; отдельный LB
addons/openwebui/   OpenWebUI (чат-морда): values к чарту helm.openwebui.com,
                    HTTPRoute — manifests/. Ставит terraform (install_openwebui)
addons/n8n/          n8n (автоматизации): values к community-чарту
                    (community-charts.github.io), HTTPRoute — manifests/.
                    Ставит terraform (install_n8n)
addons/cnpg/         CloudNativePG: оператор (helm, terraform) + кластеры БД
                    litellm-db/n8n-db/openwebui-db (CRD — рендер + kubectl:
                    rendered/cnpg-clusters.yaml)
addons/valkey/       общий valkey (redis) для litellm/n8n/openwebui — values к
                    bitnami-чарту, ставит terraform (install_valkey)
addons/dex/          dex — SSO/OIDC для веб-панелей: чарт charts.dexidp.io
                    (terraform), конфиг — рендер в Secret dex-config;
                    HTTPRoute + SecurityPolicy(n8n) — рендер + kubectl
addons/cert-manager/  cert-manager + Selectel DNS01-webhook: README, манифест
                    ClusterIssuer (kubectl). Чарты НЕ вендорены — из
                    charts.jetstack.io и selectel.github.io (helm-репо)
addons/gpu-operator/ NVIDIA GPU Operator, classic-режим: драйвер + device
                    plugin (nvidia.com/gpu) + DCGM (вендорен v26.7.0,
                    GitHub-тег — NGC helm отдаёт 403). Ставит terraform
                    (install_gpu_operator). Требует NodeClass с
                    installNvidiaDevicePlugin: false (kubectl)
addons/dra-test/    DRA (тест, НЕ production): standalone-чарт
                    dra-driver-nvidia-gpu v0.5.0 (вендорен) РЯДОМ с device
                    plugin'ом gpu-operator'а (gpuResourcesEnabledOverride);
                    шаринг GPU по памяти (ConsumableShares). Причина тестового
                    статуса — Karpenter без DynamicResources не провижинит
                    ноды под DRA-поды (подробности и грабли — в README)
addons/observability/   Observability-стек (из апстрим-папки ai-ml-observability):
                    Prometheus+Grafana+Alertmanager, OpenSearch+Fluent Bit,
                    ServiceMonitor'ы aibrix/litellm/CNPG/n8n/vLLM/DCGM,
                    дашборды и алерты; OIDC-Grafana через dex, HTTPRoute —
                    kubectl (rendered/httproute-grafana.yaml)
addons/external-dns-selectel/
                    Свой мини-чарт: external-dns + Selectel-webhook sidecar
                    (upstream-чарта нет). Зона DNS и dns-пользователь —
                    infra/01-cluster/dns.tf
addons/karpenter/   NodeClass + NodePool'ы под GPU по регионам (ru-6/, ru-7/) —
                    применяются kubectl, не terraform
addons/inference-charts/
                    ОСНОВНОЙ путь деплоя моделей (вендорен,
                    v0.2.6): terraform ставит
                    helm-релизы из deploy_models (blueprint.tfvars); веса —
                    из S3. Патчи шаблона — README аддона
                    (hfTokenSecret.enabled, extraVolumes, gpuNames/
                    gpuMinVramGb, nodeSelector, service.portName, strategy)
addons/models/      Модели vLLM: Job загрузки весей из HuggingFace (рендерит
                    terraform), ModelAdapter-finqa (kubectl); сами деплои —
                    чарт addons/inference-charts (helm-релизы из terraform:
                    deploy_models в blueprint.tfvars).
                    Каждый файл — мультидок: Deployment + якорный Service
                    (без него aibrix router даёт 503 BackendNotFound).
                    ModelAdapter-finqa.yaml — quickstart LoRA через aibrix
                    (direct-режим, применяется kubectl).
                    Монтирование S3 — csi-s3 (helm, install_csi_s3).
                    Init-jobs админов панелей: job-init-admin.yaml (openwebui),
                    job-init-owner.yaml (n8n) — применяет terraform (install_dex)
README.md           Архитектура, quickstart, rationale решений
```

## Инварианты (нарушать нельзя)

1. **Два terraform-корня не объединять.** Провайдеры helm/kubernetes не могут
   зависеть от ресурсов, созданных в том же apply (kubeconfig известен только
   после кластера). 01-cluster → output kubeconfig → 02-addons через переменную.
2. **CRD-ресурсы (SelectelNodeClass, NodePool, PodAutoscaler, ModelAdapter,
   StormService) — только через kubectl-манифесты**, не через
   `kubernetes_manifest` в terraform: CRD не зарегистрированы в API на этапе
   plan → terraform падает. Поэтому `addons/karpenter/**` (NodeClass + NodePool'ы
   по регионам) применяются
   руками (это же путь из документации Karpenter).
3. **Karpenter и Cluster Autoscaler MKS взаимоисключающие.** В 01-cluster
   держим `enable_autorepair = false`, нодгруппы без `enable_autoscale`.
   GPU-нодгруппы в terraform не описываем вовсе — ноды создаёт Karpenter
   (чарт Selectel `0.4.0`, OCI `ghcr.io/selectel/mks-charts`, helm_release
   в 02-addons; историческая справка: с 2026-09-10 по 2026-09-15 стояла
   ручная кастомная сборка 48f2256 — вошла в релиз 0.4.0 как поле
   SelectelNodeClass.installNvidiaDevicePlugin).
4. **Порядок values AIBrix**: сначала `chart/stable.yaml` (пин образов
   v0.7.0), потом `helm/values-selectel-mks.yaml` — побеждает последний.
   Дефолтный `values.yaml` чарта пиннит `:nightly` — никогда не ставить
   AIBrix без stable.yaml.
5. **Версии пиннуты** и поднимаются отдельным осознанным изменением:
   karpenter chart `0.4.0`, envoy gateway `v1.2.8`, AIBrix `v0.7.0`
   (вендорен в `addons/aibrix/chart/`), LiteLLM `v1.85.1` / чарт `1.1.3`
   (вендорен в `addons/litellm/chart/`), cert-manager chart `v1.21.1` (не
   вендорен — remote-репо jetstack), cert-manager-webhook-selectel `1.4.0`
   (helm-репо selectel.github.io), external-dns `v0.22.0` + Selectel
   DNS-webhook `v0.2.0` (пины в `addons/observability/   Observability-стек (из апстрим-папки ai-ml-observability):
                    Prometheus+Grafana+Alertmanager, OpenSearch+Fluent Bit,
                    ServiceMonitor'ы aibrix/litellm/CNPG/n8n/vLLM/DCGM,
                    дашборды и алерты; OIDC-Grafana через dex, HTTPRoute —
                    kubectl (rendered/httproute-grafana.yaml)
addons/external-dns-selectel/values.yaml`),
   OpenWebUI `v0.11.3` / чарт `16.5.0` (helm.openwebui.com), n8n `2.38.4` /
   чарт `1.24.40` (community-charts.github.io; официального чарта n8n нет,
   8gears-чарт доступен только через OCI — не проверялся), GPU Operator
   v26.7.0 (вендорен в addons/gpu-operator/chart, драйвер 595.91.07,
   classic: device plugin), DRA-драйвер v0.5.0 / чарт
   kubernetes-sigs/dra-driver-nvidia-gpu v0.5.0 (вендорен в
   addons/dra-test/chart — тестовый аддон, НЕ ставится terraform),
   CNPG chart `0.29.0` (cloudnative-pg.github.io, оператор 1.30.0 — не
   вендорен, remote-репо), valkey chart `6.2.19` (charts.bitnami.com) +
   образ `bitnamilegacy/valkey:8.1.3` (свежих versioned-тегов bitnami нет),
   dex chart `0.24.1` (charts.dexidp.io, dex 2.44.0), inference-charts
   `0.2.6` (вендорен в addons/inference-charts/chart), csi-s3 chart
   `0.43.7` (yandex-cloud.github.io/k8s-csi-s3, mounter geesefs).
6. **Драйверы GPU — два пути, не смешивать**: (a) предустановленные
   драйверы Selectel (`install_nvidia_device_plugin = true` для GPU-нод;
   в system-группе CPU — false) — обязателен при автоскейлинге MKS
   (Cluster Autoscaler): с GPU Operator он не работает; (b) GPU Operator
   (classic, `install_gpu_operator`) — ставит драйверы сам; допустим
   только с Karpenter (автоскейлинг MKS выключен) — текущая конфигурация
   репозитория. При возврате к автоскейлеру MKS — только путь (a).
7. Секретов в репозитории нет и не должно быть: креды — через
   `blueprint.tfvars` (единый, в .gitignore) или `TF_VAR_*`. Karpenter берёт
   креды из secret `cloud-config` в kube-system (создаётся MKS сам).
8. **Terraform-команды, меняющие состояние (apply, destroy, import,
   state rm), — только с явного согласия пользователя.** Каждый раз
   согласовываем перед запуском, без автозапусков. Читающие команды
   (fmt, validate, plan) — без ограничений.
9. **Доступ к кластеру — только через kubeconfig из output корня 01-cluster**
   (`terraform -chdir=infra/01-cluster output -raw kubeconfig_path`, см.
   Процедуры): любые клиенты kube-api — kubectl, helm, библиотеки — работают
   только с ним; `~/.kube/config` и облачные CLI не используются.
   Исключение: переменная `KUBECONFIG` допустима, если указывает на тот же
   файл (сверить путь с output корня 01-cluster).
10. **Ноды кластера вручную НЕ удалять** (`kubectl delete node` — никогда):
   kubectl-объект Node — отражение, а не владелец ноды; ручное удаление
   расходит state с MKS/karpenter. Удаление ноды — только через:
   • NodeClaim karpenter (kubectl delete nodeclaim <имя>) — для
     GPU-нод, созданных karpenter;
   • MKS API — скейл-вниз нодгруппы в корне 01-cluster (terraform apply
     с уменьшенным count/размером нодгруппы).
   (Про грабли дрейна при удалении — addons/gpu-operator/README.md.)

## Процедуры

**Получение kubeconfig** (кластер уже создан — корень `infra/01-cluster`
применён): terraform записывает kubeconfig в файл (по умолчанию
`infra/01-cluster/kubeconfig`, в .gitignore, права 0600) и отдаёт путь
через output:
```bash
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
```
Любая работа с кластером — `kubectl`, `helm`, другие клиенты kube-api (curl к
api-server, клиентские библиотеки) — только с этим kubeconfig. Не использовать
`~/.kube/config`, облачные CLI или иные kubeconfig: единственный источник —
этот файл из state корня 01-cluster. Если файл устарел или доступ не проходит —
повторный apply/refresh корня `01-cluster` перезапишет его свежим.

Если в окружении уже задан `KUBECONFIG`, перед работой с кластером сверить
его значение с output (`terraform -chdir=infra/01-cluster output -raw
kubeconfig_path`): совпадает путь — использовать как есть, не совпадает —
переопределить на output корня 01-cluster.

**Обновление vendored чарта AIBrix** (например v0.7.0 → v0.7.1):
```bash
git clone --depth 1 --branch vX.Y.Z https://github.com/vllm-project/aibrix.git /tmp/aibrix
rm -rf addons/aibrix/chart && cp -r /tmp/aibrix/dist/chart addons/aibrix/chart
```
Затем вручную: обновить версии в `addons/aibrix/README.md` и проверить
`helm template` (см. проверки). CRD при upgrade helm не обновляет —
упомянуть в changelog: `kubectl apply -f addons/aibrix/chart/crds/`.

**⚠ Локальные патчи вендоренных чартов** — переносятся вручную после каждого
обновления (ищи «ЛОКАЛЬНЫЙ ПАТЧ» в шаблонах):
- `addons/aibrix/chart/templates/gateway-plugin/deployment.yaml` —
  values-хук `gatewayPlugin.affinity` (дефолт — исходный hardcoded-блок);
- `addons/aibrix/chart/templates/metadata-service/redis.yaml` —
  affinity из `metadata.affinity`;
- `addons/inference-charts/chart/templates/vllm-deployment.yaml` и
  `chart/values.yaml` — патчи для Selectel: hfTokenSecret.enabled,
  extraVolumes/extraVolumeMounts (PVC csi-s3), nodeSelector/tolerations
  (GPU-пулы Karpenter), service.portName (ServiceMonitor observability),
  strategy; дополнительно: s3-model-copy.yaml (образ Job'а s3ModelCopy из
  registry Selectel), _helpers.tpl (s3ModelCopyAffinity — лейбл
  karpenter.k8s.selectel/instance-local-disk, ключ requireLocalDisk); ветки
  недоступных в MKS ускорителей вырезаны из шаблонов и values; список
  патчей и чистки —
  addons/inference-charts/README.md (маркеры в шаблонах не ставятся);
- `addons/aibrix/chart/templates/prometheus/monitor.yaml` — ServiceMonitor
  контроллера: порт `http` вместо `https` и селектор
  `app.kubernetes.io/component=aibrix-controller-manager` вместо
  `control-plane=controller-manager` (в v0.7.0 Service не имеет ни порта
  `https`, ни лейбла `control-plane` — апстримовский SM не матчит ничего;
  метрики контроллера — обычный HTTP на :8080, без kube-rbac-proxy).
  Включается `prometheus.enable: true` в values.

(Патч envoyDaemonSet в gateway-instance/gateway.yaml удалён 09.09.2026:
нужен был только для пула внешнего LB AIBrix, а LB убран — сервис
дата-плейна теперь ClusterIP, хватает upstream `envoyDeployment`.)

**Изменение набора GPU-пулов**: добавить/править yaml в `addons/karpenter/ru-<регион>/`
(пул одного GPU в разных регионах — отдельный файл в каждой директории,
зоны только своего региона), зоны — по матрице доступности Selectel
(docs.selectel.ru), не выдумывать.

**Ожидание готовности vLLM-подов**: если веса уже загружены в PVC
(job завершён / модель запускалась ранее), под стартует за минуты —
geesefs читает файлы без повторной загрузки, ждём короткими интервалами
(10–30 с) со сверкой лога/ready. Долгое ожидание — только первый запуск:
чтение холодных весов с S3 через FUSE или установка драйвера на свежей
GPU-ноде. `startupProbe.failureThreshold` в манифестах — потолок защиты
медленного сценария, не задержка: он не замедляет быстрый старт,
уменьшать его не нужно.

## Карта связей: изменил — синхронизируй

Главная причина расхождений — сущность живёт в нескольких файлах
(код + дефолты + tfvars-example + README + AGENTS + доки аддона).
Перед коммитом любых содержательных правок:

1. **Grep-правило:** rg по всей репе имени/версии/тумблера, который меняете
   (`rg -F 'v1.85.1'`), и по СТАРОМУ значению — обновить или осознанно
   оставить каждое вхождение. Примеры найденных расхождений: дефолт
   тумблера ≠ таблица README; путь `aibrix/chart/crds/` без `addons/`;
   «apply не выполнялся» при проверенном end-to-end; «заполните
   litellm_hostname» при отсутствии такой переменной (это local из
   `dns_zone_name`).
2. **Diff-правило:** `git diff --stat` — если из связанной пары файлов
   (см. таблицу) изменён только один, вы что-то забыли.

| Изменил | Обязательно синхронизировать |
|---|---|
| Версию чарта/образа (дефолт `variables.tf`) | инвариант 5 AGENTS.md; README (таблица тумблеров / абзац «Версии пиннуты»); README аддона; для вендореных чартов — процедура обновления и перенос патчей (раздел «Процедуры») |
| Тумблер `install_*` / его дефолт | `variables.tf` (описание + validations) ↔ `main.tf` (helm_release/count) ↔ `blueprint.tfvars.example` ↔ таблица в README ↔ раздел «Структура» AGENTS.md; если появилось новое обязательное поле (домен, StorageClass, email) — шаги в README «Быстрый старт»/«Домен и DNS» |
| Новый аддон `addons/<имя>/` | `main.tf` + `variables.tf` 02-аддонов; `blueprint.tfvars.example`; README (таблица + структура); AGENTS.md (структура, при необходимости — инвариант и строка рендера в «Проверках перед коммитом») |
| Новый пресет модели `values-<п>.yaml` | алиас в `hf_models` = `modelPath` пресета (ключ `deploy_models` = `--served-model-name`); README «Быстрый старт» (список пресетов) |
| GPU-пул `addons/karpenter/ru-<регион>/` | команды в README «Быстрый старт»; лейблы пула `gpu`/`gpu-vram` ↔ `gpuNames`/`gpuMinVramGb` пресетов inference-charts; зоны — только по матрице доступности Selectel |
| Шаблон `addons/*/manifests/*.tpl` | `infra/02-addons/rendered/` — генерится terraform'ом (local_file), руками не править; после правки tpl — apply или ручной рендер |
| Хосты панелей (locals `ai/chat/n8n/auth/grafana/osd.<домен>` в `main.tf`) | `config.yaml.tpl` dex (redirects/callbacks), README; это locals — в tfvars НЕ выносить и в доках «переменными» не называть |
| Имя/порт/лейблы сервиса в чарте (напр. `service.portName` inference-charts) | ServiceMonitor'ы в `addons/observability/` (селекторы и имена портов) |
| Структуру директорий | раздел «Структура» AGENTS.md и README |

3. **Докам нельзя верить больше, чем коду:** упоминая в доках переменную,
   команду или путь — проверяйте существование (rg в `variables.tf` / ls).
   Читающие доки не должны догадываться, что инструкция устарела.

## Мультиагентный режим

Когда несколько ИИ-агентов работают над репозиторием/кластером одновременно
(например, параллельные лейны с кодом, доками и исследованием):

- **Оркестрация.** Работой управляет один родительский (оркестрирующий)
  агент. Агенты не общаются напрямую друг с другом — только результатами
  через родителя (с фактами, командами и выводом проверок). Ответственность
  за итог и за сверку чужих результатов — у родителя.
- **Владение файлами.** Один файл одновременно меняет только один агент;
  параллельные писатели на общем файле запрещены — последовательность
  правок задаёт родитель. Каждый terraform-корень (01/02) в один момент
  времени редактирует не более одного агента.
- **Terraform state.** Мутирующие команды (apply, destroy, import,
  state rm) выполняет только один агент на корень: параллельные apply
  дают state-локи и порчу конфигураций. Читающие (plan, show, state list)
  — можно параллельно. Согласование мутаций — по инварианту 8: агент
  запрашивает у родителя, родитель — у пользователя; без явного согласия
  не запускается ни один apply.
- **Кластер.** kubectl-мутации (apply, delete, scale, patch, rollout) —
  те же правила, что и terraform: один исполнитель, явное согласие на
  деструктивное, читающие команды (get, logs, describe) свободны.
  kubeconfig — только из output корня 01-cluster (инвариант 9).
- **Изоляция корней.** Применение 02-аддонов возможно только после
  завершённого apply корня 01-cluster (зависимость по kubeconfig).
  Параллельные apply в независимых корнях допустимы, но 01 и 02 таковыми
  не являются.
- **Границы задачи.** Агент не выходит за пределы поставленной задачи:
  смежная проблема — сообщает родителю, а не чинит сам. Секреты в вывод
  не печатаются (инвариант 7).
- **Верификация.** Каждый агент после правок выполняет проверки из
  раздела «Проверки перед коммитом» для затронутых файлов и передаёт
  вывод родителю. Финальные проверки всего репозитория и коммит — родитель.

## Проверки перед коммитом (обязательны)

```bash
# Terraform (оба корня; для plan в 02-addons нужен существующий kubeconfig)
cd infra/01-cluster && terraform fmt -check && terraform validate
cd ../02-addons && terraform fmt -check && terraform validate \
  -var 'kubeconfig_path=/dev/null' -var 'cluster_id=x'

# Рендер чарта AIBrix с нашими values — должен давать ~39 объектов без ошибок
helm template aibrix addons/aibrix/chart \
  -f addons/aibrix/chart/stable.yaml \
  -f addons/aibrix/helm/values-selectel-mks.yaml > /dev/null

# Рендер LiteLLM (БД — внешний CNPG, встроенный postgres-subchart выключен)
helm template litellm addons/litellm/chart \
  -f addons/litellm/values-selectel-mks.yaml.tpl > /dev/null \
  --set-string postgresql.auth.password=x   # ${auth_hostname} в values — плейсхолдер

# Рендер valkey (remote-чарт битнами; secret-заглушка)
helm template valkey bitnami/valkey --version 6.2.19 \
  -f addons/valkey/values-selectel-mks.yaml --set auth.existingSecret=x > /dev/null

# Рендер dex (remote-чарт; config-заглушка из секрета)
helm template dex dexidp/dex --version 0.24.1 \
  -f addons/dex/values-selectel-mks.yaml > /dev/null

# Рендер external-dns-selectel (свой чарт; креды тестовые)
helm template external-dns addons/external-dns-selectel \
  --set-string domain=example.com \
  --set-string selectel.username=dns-automation \
  --set-string selectel.accountId=1 \
  --set-string selectel.projectId=p \
  --set-string selectel.password=x > /dev/null

# cert-manager и cert-manager-webhook-selectel — remote-чарты (не вендорены),
# локальный рендер не гоняется: достаточно terraform validate/plan в 02-addons
# (провайдер helm скачивает чарт на apply). При желании руками:
#   helm template cert-manager cert-manager --repo https://charts.jetstack.io --version v1.21.1 > /dev/null

# Рендер GPU Operator (classic-режим: без gpuCluster API-флаги не нужны;
# флаг нужен только при DRA-значениях — тогда добавьте
# --api-versions resource.k8s.io/v1/DeviceClass)
helm template gpu-operator addons/gpu-operator/chart \
  -f addons/gpu-operator/helm/values-selectel-mks.yaml > /dev/null

# Рендер DRA-драйвера (тестовый аддон; тоже офлайн-DRA-API)
helm template nvidia-dra-driver addons/dra-test/chart \
  -n nvidia-dra-driver --api-versions resource.k8s.io/v1/DeviceClass \
  -f addons/dra-test/values-selectel-mks.yaml > /dev/null

# Рендер inference-charts: пресет Selectel + пример и дефолты апстрима
helm template q addons/inference-charts/chart \
  -f addons/inference-charts/values-selectel-mks.yaml \
  -f addons/inference-charts/values-qwen3-32b-s3.yaml > /dev/null
helm template q addons/inference-charts/chart \
  -f addons/inference-charts/values-selectel-mks.yaml \
  -f addons/inference-charts/values-deepseek-r1-distill-llama-8b-s3.yaml > /dev/null
helm template q addons/inference-charts/chart > /dev/null

# YAML-манифесты валидны (мультидок-файлы — safe_load_all, см. vllm-lora-base.yaml)
for f in addons/karpenter/*.yaml addons/karpenter/ru-*/*.yaml \
         addons/dra-test/manifests/*.yaml \
         addons/dra-test/*.yaml \
         addons/aibrix/manifests/*.yaml \
         addons/models/*.yaml \
         addons/cert-manager/manifests/*.yaml; do \
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" || exit 1; done
for f in addons/inference-charts/values-*.yaml; do \
  python3 -c "import yaml; yaml.safe_load(open('$f'))" || exit 1; done
```

`terraform apply` на реальном облаке в CI не гоняется — сетевые/квотные вещи
проверяются вручную на тестовом проекте.

## Стиль и соглашения

- Язык: русский для доков и комментариев; имя файлов/ресурсов — английский.
- Тон комментариев и доков — нейтральный технический, без разговорных слов
  («жрёт», «снесён», «грохнуть», «торчит», «хардкодим») — лаконичные
  нейтральные аналоги: «требует», «удалён», «открыт наружу», «задано явно».
  Меткие цитаты из документации upstream — можно, в кавычках с источником.
  Это относится и к комментариям в коде, и к докам, и к commit-сообщениям.
- Эпистемическая честность из `addons/aibrix/docs/` действует и на код:
  неподтверждённые вещи помечаем «не проверено», версии указываем явно.
- Каждый неочевидный выбор объяснён комментарием или разделом в README
  (почему два корня, почему NodePool'ы через kubectl, почему чарт вендорен).
  Не удаляйте эти пояснения при рефакторинге.
- Изменения в `addons/aibrix/docs/` синхронизируйте с фактами (версии чартов,
  имена ресурсов), которые реально есть в `addons/aibrix/chart/` и values.
- Diff минимальный: не перестраивать структуру без явной просьбы.
