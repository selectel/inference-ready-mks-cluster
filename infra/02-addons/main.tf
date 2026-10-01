# =============================================================================
# Шаг 2: компоненты в кластере. Каждый включается своим тумблером в tfvars.
#   install_karpenter     — автоскейлер нод (чарт Selectel, OCI ghcr.io)
#   install_envoy_gateway — шлюз данных + Gateway API CRD
#   install_aibrix        — контроль-плейн LLM-инференса (зависит от Envoy GW)
#   deploy_models          — модели vLLM через чарт inference-charts
# =============================================================================

# --- Karpenter (Selectel) -----------------------------------------------------
# Возвращён в terraform 2026-09-15 (чарт 0.4.0: кастомная сборка 48f2256,
# стоявшая вручную с 2026-09-10, вошла в релиз — поле SelectelNodeClass
# installNvidiaDevicePlugin). Живой релиз импортируется в state:
# terraform import helm_release.karpenter[0] kube-system/karpenter.
# CRD чарта при upgrade helm не обновляет: kubectl apply -f crds/ из чарта
# (см. README, «Обновление Karpenter»).

resource "helm_release" "karpenter" {
  count = var.install_karpenter ? 1 : 0

  name       = "karpenter"
  repository = "oci://ghcr.io/selectel/mks-charts"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = "kube-system"
  timeout    = 600

  set = [
    {
      name  = "controller.settings.clusterID"
      value = var.cluster_id
    },
  ]

  # CRD чарта (SelectelNodeClass, NodePool, NodeClaim) ставятся при первом install;
  # при upgrade обновляются только вручную — см. README.
}

# --- Envoy Gateway ------------------------------------------------------------
# AIBrix использует EnvoyPatchPolicy -> extensionApis.enableEnvoyPatchPolicy=true обязательно.
# Selectel официально рекомендует Envoy Gateway для Gateway API в MKS.

resource "helm_release" "envoy_gateway" {
  count = var.install_envoy_gateway ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.envoy_gateway_chart_version
  namespace        = "envoy-gateway-system"
  create_namespace = true

  set = [
    {
      name  = "config.envoyGateway.extensionApis.enableEnvoyPatchPolicy"
      value = "true"
    },
  ]
}

# --- AIBrix -------------------------------------------------------------------
# Чарт v0.7.0 вендорен в ../../addons/aibrix/chart (в upstream нет OCI/helm-репозитория).
# Порядок values важен: сначала stable.yaml (пин образов v0.7.0), потом наш values
# (Octavia-аннотации LB, HA-флаги) — побеждает последний.

resource "helm_release" "aibrix" {
  count = var.install_aibrix ? 1 : 0

  name             = "aibrix"
  chart            = "../../addons/aibrix/chart"
  namespace        = "aibrix-system"
  create_namespace = true
  timeout          = 900

  values = [
    file("../../addons/aibrix/chart/stable.yaml"),
    file("../../addons/aibrix/helm/values-selectel-mks.yaml"),
    # ServiceMonitor AIBrix рендерится только при observability-стеке:
    # без его CRD monitoring.coreos.com helm-провайдер не может смаппить
    # kind и релиз падает (values-selectel-mks.yaml содержит статический
    # prometheus.enable: true — переопределяем по тумблеру).
    yamlencode({ prometheus = { enable = var.install_observability } }),
  ]

  # AIBrix создаёт Gateway/HTTPRoute при установке -> сначала нужны Gateway API CRD.
  depends_on = [helm_release.envoy_gateway]
}

# --- Модели vLLM (addons/models/) ------------------------------------------------
# Манифесты — обычные Deployment + «якорный» Service (core API, мультидок)
# → kubernetes_manifest безопасен. Веса — из S3 (PVC models, SC csi-s3):
# деплой по умолчанию — через сохранение весов в S3 (job hf-models-upload
# ниже). CR AIBrix (PodAutoscaler, ModelAdapter) остаются в
# addons/aibrix/manifests — kubectl (CRD неизвестны на plan).

locals {
  # Values каждого helm-релиза модели: базовый пресет Selectel → пресет
  # модели (values-<preset>.yaml из addons/inference-charts/) → точечные
  # переопределения из blueprint (deploy_models.<имя>.values).
  model_values = { for name, m in var.deploy_models : name => compact([
    file("../../addons/inference-charts/values-selectel-mks.yaml"),
    m.preset != null ? file("../../addons/inference-charts/values-${m.preset}.yaml") : "",
    m.values != null ? yamlencode(m.values) : "",
  ]) }
}

resource "helm_release" "models" {
  for_each = var.deploy_models

  name      = each.key
  chart     = "../../addons/inference-charts/chart"
  namespace = "default"
  # Холодный старт vLLM (S3 через geesefs) — десятки минут: не ждать готовности
  # подов в apply (helm-таймаут всё равно меньше)
  wait    = false
  timeout = 300

  values = local.model_values[each.key]

  # PVC models (SC csi-s3) — том с весами, монтируется базовым пресетом
  depends_on = [kubernetes_manifest.models_pvc]
}

# PVC на весь S3-контейнер (SC csi-s3 с singleBucket): маппинг модели по имени
# = каталог верхнего уровня в томе (--model /models/<алиас>).
# RWX: job загрузки весов пишет в этот же том (geesefs транслирует записи
# в S3 в префикс тома pvc-<uid>), поды vLLM монтируют его readOnly: true.
resource "kubernetes_manifest" "models_pvc" {
  count = var.install_csi_s3 ? 1 : 0

  manifest = {
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata = {
      name      = "models"
      namespace = "default" # ns манифестов моделей (addons/models/*.yaml)
    }
    spec = {
      accessModes      = ["ReadWriteMany"]
      storageClassName = "csi-s3"
      resources = {
        requests = {
          # Драйвер не квотирует (бакет без лимита) — информационное значение:
          # Qwen3-32B ≈ 65 ГБ + deepseek 8B ≈ 16 ГБ + запас на другие модели
          storage = "500Gi"
        }
      }
    }
  }

  depends_on = [helm_release.csi_s3]
}

# --- LiteLLM Proxy (auth-слой, virtual keys) -----------------------------------
# Централизованные API-ключи для доступа к моделям AIBrix. Полная документация:
# addons/litellm/README.md. Секреты не в репо: master key и пароль Postgres
# генерируются random_password и уходят в кластер через Secret / set_sensitive
# (значения видны только в state, state в .gitignore).

# Стабильное имя для LiteLLM → envoy/AIBrix. EG именует свой сервис
# envoy-<ns>-<gateway>-<hash>: хэш меняется между релизами EG, а LiteLLM
# указывает api_base в values — без якоря передеплой AIBrix ломал бы связность.
# Селектор — по устойчивым owning-gateway-лейблам envoy-подов, не по имени.
resource "kubernetes_service_v1" "aibrix_gateway" {
  count = var.install_litellm ? 1 : 0

  metadata {
    name      = "aibrix-gateway"
    namespace = "envoy-gateway-system"
  }

  spec {
    selector = {
      "app.kubernetes.io/component"                    = "proxy"
      "gateway.envoyproxy.io/owning-gateway-namespace" = "aibrix-system"
      "gateway.envoyproxy.io/owning-gateway-name"      = "aibrix-eg"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 10080 # контейнерный порт envoy (envoyService: 80 → 10080)
    }
  }

  depends_on = [helm_release.aibrix]
}

resource "kubernetes_namespace_v1" "litellm" {
  count = var.install_litellm ? 1 : 0

  metadata {
    name = "litellm"
  }
}

resource "random_password" "litellm_master_key" {
  count = var.install_litellm ? 1 : 0

  length  = 32
  special = false # sk-... ключ без спецсимволов, чтобы не резался шеллом
}

resource "kubernetes_secret_v1" "litellm_masterkey" {
  count = var.install_litellm ? 1 : 0

  metadata {
    name      = "litellm-masterkey"
    namespace = kubernetes_namespace_v1.litellm[0].metadata[0].name
  }

  data = {
    masterkey = "sk-${random_password.litellm_master_key[0].result}"
  }

  # Обновление ключа инвалидирует сессии админки, но НЕ virtual keys (они в БД)
  lifecycle {
    ignore_changes = [data["masterkey"]] # ротация — только вручную, осознанно
  }
}

resource "helm_release" "litellm" {
  count = var.install_litellm ? 1 : 0

  name      = "litellm"
  chart     = "../../addons/litellm/chart"
  namespace = "litellm"
  # Не ждать готовности подов в apply: БД litellm-db — внешний CNPG-кластер,
  # применяемый kubectl'ом ПОСЛЕ этого apply (CRD-инвариант: оператор ставится
  # этим же apply). С ожиданием первый apply всегда завершается failed-релизом.
  wait    = false
  timeout = 600

  values = [
    # values — шаблон (домен только в blueprint, подставляется из зоны)
    templatefile("../../addons/litellm/values-selectel-mks.yaml.tpl", {
      auth_hostname    = local.auth_hostname
      litellm_hostname = local.litellm_hostname
    }),
  ]

  # БД — внешний кластер CNPG litellm-db (пароль — в секрете litellm-db-app,
  # создаёт оператор после kubectl apply rendered/cnpg-clusters.yaml),
  # Redis — Valkey (valkey-auth), SSO — dex (dex-litellm-client)

  depends_on = [
    kubernetes_secret_v1.litellm_masterkey,
    helm_release.aibrix, # бэкендом модели LB-сервис envoy от AIBrix
    kubernetes_secret_v1.valkey_auth,
    kubernetes_secret_v1.dex_client,
  ]
}

resource "random_password" "litellm_db_password" {
  count = var.install_litellm ? 1 : 0

  length  = 24
  special = false
}

# ⛠ МИГРАЦИЯ 2026-09-11: БД LiteLLM переведена на внешний кластер CNPG
# litellm-db (addons/cnpg) — встроенный postgres-subchart больше не ставится.
# Пароль выше временно сохранён в state, чтобы random_password не пересоздавался
# (чужие ресурсы не ломаются); удалить после сверки plan = no-op.

# --- CNPG: PostgreSQL для litellm / n8n / openwebui ----------------------------
# Оператор (helm) — terraform; кластеры Cluster (CRD) — kubectl из
# rendered/cnpg-clusters.yaml (инвариант №2). Доки: addons/cnpg/README.md.

resource "helm_release" "cnpg" {
  count = var.install_cnpg ? 1 : 0

  name             = "cloudnative-pg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = var.cnpg_chart_version
  namespace        = "cnpg-system"
  create_namespace = true

  values = [yamlencode({
    # Оператор — на system-нодах (GPU Karpenter — мимо); кластеры БД
    # назначаются на system в самих манифестах Cluster
    nodeSelector = { nodegroup = "system" }
  })]
}

# Рендер манифестов кластеров (kubectl apply -f rendered/cnpg-clusters.yaml).
# Кластеры — в ns самих сервисов: секрет <кластер>-app должен лежать в ns
# потребителя (secretKeyRef не умеет чужие namespace).
resource "local_file" "cnpg_clusters" {
  count = var.install_cnpg ? 1 : 0

  content = templatefile("../../addons/cnpg/manifests/clusters.yaml.tpl", {
    services = [
      { cluster = "litellm-db", namespace = "litellm", database = "litellm" },
      { cluster = "n8n-db", namespace = "n8n", database = "n8n" },
      { cluster = "openwebui-db", namespace = "openwebui", database = "openwebui" },
    ]
    instances     = var.cnpg_instances
    storage_size  = var.cnpg_storage_size
    storage_class = var.storage_class_name
    # Бэкапы в отдельный S3-контейнер — только при объектном хранилище
    # из 01-корня (креды и бакет известны через remote state).
    backup_bucket = var.create_object_storage ? local.s3_backup_bucket : ""
    s3_endpoint   = local.s3_endpoint
  })

  filename        = "rendered/cnpg-clusters.yaml"
  file_permission = "0644"
}

# Креды S3 для бэкапов CNPG (барман) — по копии Secret в каждом ns кластера
# БД. Имена ключей ACCESS_KEY_ID / SECRET_ACCESS_KEY — как в доке CNPG.
resource "kubernetes_secret_v1" "cnpg_backup_credentials" {
  for_each = var.install_cnpg && var.create_object_storage ? toset(["litellm", "n8n", "openwebui"]) : toset([])

  metadata {
    name      = "cnpg-backup-credentials"
    namespace = each.key
  }

  data = {
    ACCESS_KEY_ID     = local.s3_access_key
    SECRET_ACCESS_KEY = local.s3_secret_key
  }

  depends_on = [kubernetes_namespace_v1.litellm, kubernetes_namespace_v1.n8n, kubernetes_namespace_v1.openwebui]
}

# --- Valkey: общий redis для litellm / n8n / openwebui ------------------------

resource "random_password" "valkey_password" {
  count = var.install_valkey ? 1 : 0

  length  = 24
  special = false
}

resource "kubernetes_namespace_v1" "valkey" {
  count = var.install_valkey ? 1 : 0

  metadata {
    name = "valkey"
  }
}

# Основной секрет (потребляет чарт) + копии в ns сервисов (secretKeyRef
# не умеет чужие namespace) — тот же паттерн, что у litellm-masterkey.
resource "kubernetes_secret_v1" "valkey_auth" {
  for_each = var.install_valkey ? toset(["valkey", "litellm", "n8n", "openwebui"]) : toset([])

  metadata {
    name      = "valkey-auth" # одинаковое имя во всех ns — копии для secretKeyRef
    namespace = each.key
  }

  data = {
    valkey-password = random_password.valkey_password[0].result
  }

  depends_on = [
    kubernetes_namespace_v1.valkey,
    kubernetes_namespace_v1.litellm,
    kubernetes_namespace_v1.n8n,
    kubernetes_namespace_v1.openwebui,
  ]
}

resource "helm_release" "valkey" {
  count = var.install_valkey ? 1 : 0

  name = "valkey"
  # Чарт — через зеркало Selectel: и charts.bitnami.com (Broadcom, 403), и
  # registry-1.docker.io (401/timeout из сети кластера и корп. сетей) недоступны
  repository = "oci://docker-registry.selectel.ru/bitnamicharts"
  chart      = "valkey"
  version    = var.valkey_chart_version
  namespace  = kubernetes_namespace_v1.valkey[0].metadata[0].name

  values = [
    file("../../addons/valkey/values-selectel-mks.yaml"),
  ]

  set = [{
    # чарт 6.2.19 именует секцию primary.* (не master.*)
    name  = "primary.persistence.storageClass"
    value = var.storage_class_name
  }]

  depends_on = [kubernetes_secret_v1.valkey_auth]
}

# URL websocket-менеджера OpenWebUI (db 2): отдельный секрет — чарт ждёт
# готовую строку redis://:<пароль>@<хост>:<порт>/<db>
resource "kubernetes_secret_v1" "openwebui_redis_url" {
  count = (var.install_openwebui && var.install_valkey) ? 1 : 0

  metadata {
    name      = "openwebui-redis-url"
    namespace = "openwebui"
  }

  data = {
    "redis-url" = "redis://:${random_password.valkey_password[0].result}@valkey-primary.valkey.svc.cluster.local:6379/2"
  }
}

# --- OpenWebUI / n8n (прикладные веб-морды) ----------------------------------

resource "kubernetes_namespace_v1" "openwebui" {
  count = var.install_openwebui ? 1 : 0

  metadata {
    name = "openwebui"
  }
}

# Копия master-key LiteLLM в ns openwebui: OPENAI_API_KEY для OpenWebUI через
# openaiApiKeyExistingSecret (secretKeyRef не умеет ссылаться на чужой namespace).
# Ручная ротация ключа — менять и в kubernetes_secret.litellm_masterkey (см. её lifecycle).
resource "kubernetes_secret_v1" "openwebui_litellm_masterkey" {
  count = var.install_openwebui ? 1 : 0

  metadata {
    name      = "litellm-masterkey"
    namespace = kubernetes_namespace_v1.openwebui[0].metadata[0].name
  }

  data = {
    masterkey = "sk-${random_password.litellm_master_key[0].result}"
  }
}

resource "helm_release" "openwebui" {
  count = var.install_openwebui ? 1 : 0

  name       = "openwebui"
  repository = "https://helm.openwebui.com"
  chart      = "open-webui"
  version    = var.openwebui_chart_version
  namespace  = kubernetes_namespace_v1.openwebui[0].metadata[0].name
  # Не ждать готовности подов в apply: БД openwebui-db — внешний CNPG-кластер,
  # применяемый kubectl'ом ПОСЛЕ этого apply (CRD-инвариант). С ожиданием
  # первый apply завершается failed-релизом.
  wait    = false
  timeout = 600

  values = [
    templatefile("../../addons/openwebui/values-selectel-mks.yaml.tpl", {
      auth_hostname = local.auth_hostname
    }),
  ]

  set = [{
    name  = "persistence.storageClass"
    value = var.storage_class_name
  }]

  depends_on = [
    kubernetes_secret_v1.openwebui_litellm_masterkey,
    # OIDC-клиент dex + URL valkey (websocket) должны существовать до старта подов
    kubernetes_secret_v1.dex_client,
    kubernetes_secret_v1.openwebui_redis_url,
  ]
}

# ns n8n создаётся ЭТИМ ресурсом (а не helm-релизом n8n): в ns n8n пишут
# секреты (valkey_auth, cnpg_backup_credentials, dex_client, sso-admin),
# от которых helm-релиз n8n сам зависит (валкей-креды) — при создании ns
# релизом получается цикл/гонка на свежем кластере. У helm
# create_namespace=true остаётся страховкой (на существующий ns не влияет).
resource "kubernetes_namespace_v1" "n8n" {
  count = var.install_n8n ? 1 : 0

  metadata {
    name = "n8n"
  }
}

resource "helm_release" "n8n" {
  count = var.install_n8n ? 1 : 0

  name             = "n8n"
  repository       = "https://community-charts.github.io/helm-charts"
  chart            = "n8n"
  version          = var.n8n_chart_version
  namespace        = "n8n"
  create_namespace = true
  # Не ждать готовности подов в apply: БД n8n-db — внешний CNPG-кластер,
  # применяемый kubectl'ом ПОСЛЕ этого apply (CRD-инвариант: оператор ставится
  # этим же apply). С ожиданием первый apply всегда завершается failed-релизом
  # (раньше стоял timeout 900 — тоже не спасал: БД на момент apply не созданы).
  wait    = false
  timeout = 600

  values = [
    templatefile("../../addons/n8n/values-selectel-mks.yaml.tpl", {
      n8n_hostname = local.n8n_hostname
    }),
  ]

  set = [{
    name  = "main.persistence.storageClass"
    value = var.storage_class_name
  }]

  # Креды внешней БД/Valkey (n8n-db-app создаёт оператор CNPG — кластеры
  # применяются kubectl: rendered/cnpg-clusters.yaml, см. addons/cnpg/README.md)
  depends_on = [kubernetes_namespace_v1.n8n, kubernetes_secret_v1.valkey_auth]
}

# --- GPU Operator (classic-режим: драйвер + device plugin + DCGM) --------------
# Чарт вендорен (NGC helm-репо флапает 403 — собрали из GitHub-тега v26.7.0).
# Предусловие: SelectelNodeClass с installNvidiaDevicePlugin: false (kubectl).
# После установки: NFD → драйвер 595 → DRA kubelet-plugin → ResourceSlice.
# Манифесты DRA (RCT и пр.) — addons/gpu-operator/manifests, kubectl.

resource "helm_release" "gpu_operator" {
  count = var.install_gpu_operator ? 1 : 0

  name             = "gpu-operator"
  chart            = "../../addons/gpu-operator/chart"
  namespace        = "gpu-operator"
  create_namespace = true
  timeout          = 900

  values = [
    file("../../addons/gpu-operator/helm/values-selectel-mks.yaml"),
  ]
}

# --- cert-manager + Selectel DNS01-webhook ------------------------------------
# TLS-сертификаты Let's Encrypt с DNS-01 челленджем через DNS-хостинг Selectel.
# Полная инструкция (включая ClusterIssuer): addons/cert-manager/README.md.
# Креды dns-пользователя: при create_zone_and_user=true — из state 01-корня
# (зона+пользователь созданы terraform'ом там), иначе — переменные dns_* blueprint'а.

data "terraform_remote_state" "cluster" {
  count = ((var.install_cert_manager || var.install_external_dns) && var.create_zone_and_user) || var.create_object_storage ? 1 : 0

  backend = "local"
  config = {
    path = "${path.module}/../01-cluster/terraform.tfstate"
  }
}

locals {
  # S3: креды либо из state 01-корня (create_object_storage=true), либо из
  # переменных (контейнер создан вне terraform). Бакет и endpoint — всегда
  # через переменные (одинаковы для обоих путей).
  s3_access_key = var.create_object_storage ? one(data.terraform_remote_state.cluster[*].outputs.s3_access_key) : var.s3_access_key
  s3_secret_key = var.create_object_storage ? one(data.terraform_remote_state.cluster[*].outputs.s3_secret_key) : var.s3_secret_key
  s3_endpoint   = var.create_object_storage ? one(data.terraform_remote_state.cluster[*].outputs.s3_endpoint) : var.s3_endpoint
  # Контейнер бэкапов CNPG: из state 01-корня либо из переменной бэкап-бакета
  s3_backup_bucket = var.create_object_storage ? one(data.terraform_remote_state.cluster[*].outputs.s3_backup_bucket_name) : var.backup_bucket_name

  # DNS-имена панелей: производные от зоны (ai/chat/n8n/auth.<домен>)
  auth_hostname    = "auth.${var.dns_zone_name}"
  chat_hostname    = "chat.${var.dns_zone_name}"
  n8n_hostname     = "n8n.${var.dns_zone_name}"
  litellm_hostname = "ai.${var.dns_zone_name}"
  grafana_hostname = "grafana.${var.dns_zone_name}"
  osd_hostname     = "osd.${var.dns_zone_name}"
}

locals {
  dns_user_name     = var.create_zone_and_user ? one(data.terraform_remote_state.cluster[*].outputs.dns_user_name) : var.dns_user_name
  dns_user_password = var.create_zone_and_user ? one(data.terraform_remote_state.cluster[*].outputs.dns_user_password) : var.dns_user_password
  dns_account_id    = var.create_zone_and_user ? one(data.terraform_remote_state.cluster[*].outputs.account_id) : var.dns_account_id
  dns_project_id    = var.create_zone_and_user ? one(data.terraform_remote_state.cluster[*].outputs.project_id) : var.dns_project_id
}

resource "helm_release" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  values = [yamlencode({
    # CRD ставит сам чарт (не через kubectl при upgrade — helm обновит)
    crds = { enabled = true }
    # Пиннинг на system-ноды: GPU-ноды Karpenter дороги и без taint'ов
    nodeSelector = { nodegroup = "system" }
  })]
}

# Secret с кредами для DNS01-вебхука (формат — github.com/selectel/cert-manager-webhook-selectel).
resource "kubernetes_secret_v1" "cert_manager_dns_credentials" {
  count = var.install_cert_manager ? 1 : 0

  metadata {
    name      = "selectel-dns-credentials"
    namespace = "cert-manager"
  }

  data = {
    username   = local.dns_user_name
    password   = local.dns_user_password
    account_id = local.dns_account_id
    project_id = local.dns_project_id
  }

  depends_on = [helm_release.cert_manager]
}

resource "helm_release" "cert_manager_webhook" {
  count = var.install_cert_manager ? 1 : 0

  name       = "cert-manager-webhook-selectel"
  repository = "https://selectel.github.io/cert-manager-webhook-selectel"
  chart      = "cert-manager-webhook-selectel"
  version    = var.cert_manager_webhook_chart_version
  namespace  = "cert-manager"

  values = [yamlencode({
    nodeSelector = { nodegroup = "system" }
  })]

  depends_on = [helm_release.cert_manager]
}

# --- external-dns + Selectel-webhook ------------------------------------------
# Свой мини-чарт (upstream-чарта нет): external-dns + sidecar-вебхук Selectel.
# Создаёт/обновляет DNS-записи в зоне dns_zone_name для annotated Service/Ingress.
# Полная инструкция: addons/external-dns-selectel/README.md.

resource "helm_release" "external_dns" {
  count = var.install_external_dns ? 1 : 0

  name             = "external-dns"
  chart            = "../../addons/external-dns-selectel"
  namespace        = "external-dns"
  create_namespace = true

  values = [yamlencode({
    domain       = var.dns_zone_name
    nodeSelector = { nodegroup = "system" }
    selectel = {
      username  = local.dns_user_name
      accountId = local.dns_account_id
      projectId = local.dns_project_id
      # пароль через values, не set_sensitive: helm-парсер set'ов ломается
      # на спецсимволах (запятые/скобки/баки), yamlencode экранирует всё
      password = local.dns_user_password
    }
  })]
}

# --- Рендер CRD-манифестов cert-manager (ClusterIssuer, Certificate) -------------
# КРЕДИЦИАЛЫ и email — из переменных blueprint'а. Сами объекты — CRD-ресурсы
# (инвариант №2: terraform'ом нельзя — при первом apply CRD ещё не
# зарегистрированы), поэтому terraform только рендерит файлы в rendered/,
# а применяются они kubectl'ом (команда — в output cert_apply_command).

resource "local_file" "clusterissuer" {
  count = var.install_cert_manager ? 1 : 0

  content = templatefile("../../addons/cert-manager/manifests/clusterissuer-letsencrypt.yaml.tpl", {
    letsencrypt_email = var.letsencrypt_email
  })

  filename        = "rendered/clusterissuer-letsencrypt.yaml"
  file_permission = "0644"
}

resource "local_file" "certificate_wildcard" {
  count = (var.install_cert_manager && var.dns_zone_name != "") ? 1 : 0

  content = templatefile("../../addons/cert-manager/manifests/certificate-wildcard.yaml.tpl", {
    dns_zone_name = var.dns_zone_name
  })

  filename        = "rendered/certificate-wildcard.yaml"
  file_permission = "0644"
}

# Edge-шлюз (Envoy Gateway, Gateway API): ОДИН LoadBalancer + wildcard-сертификат
# *.dns_zone_name на все сервисы кластера; новые сервисы добавляются своим
# HTTPRoute'ом (пример — addons/cert-manager/manifests/httproute-example.yaml).
# A-записи имён создаёт external-dns (source gateway-httproute), TLS терминируется
# на envoy секретом из certificate-wildcard. Требует install_envoy_gateway.
resource "local_file" "gateway_edge" {
  count = (var.install_envoy_gateway && var.dns_zone_name != "") ? 1 : 0

  content = templatefile("../../addons/cert-manager/manifests/gateway-edge.yaml.tpl", {
    dns_zone_name = var.dns_zone_name
  })

  filename        = "rendered/gateway-edge.yaml"
  file_permission = "0644"
}

# HTTPRoute LiteLLM на edge-шлюзе (отдельный файл — как и любой другой сервис).
# Условие — как у остальных панелей: зона + external-dns (A-запись) +
# cert-manager (сертификат); само имя — local (ai.<домен>).
resource "local_file" "httproute_litellm" {
  count = (var.install_litellm && var.install_external_dns && var.install_cert_manager && var.dns_zone_name != "") ? 1 : 0

  content = templatefile("../../addons/cert-manager/manifests/httproute-litellm.yaml.tpl", {
    litellm_hostname = local.litellm_hostname
  })

  filename        = "rendered/httproute-litellm.yaml"
  file_permission = "0644"
}

# --- Dex: единый SSO (OIDC) для веб-панелей -----------------------------------
# Чарт без секретов в values: полный конфиг (issuer, staticClients,
# staticPasswords) рендерится в Secret dex-config. Доки: addons/dex/README.md.

resource "random_password" "dex_client_secret_openwebui" {
  count   = var.install_dex ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "dex_client_secret_litellm" {
  count   = var.install_dex ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "dex_client_secret_n8n" {
  count   = var.install_dex ? 1 : 0
  length  = 32
  special = false
}

# Пароль админа dex: из blueprint (sso_admin_password) или генерируется —
# в обоих случаях уходит в Secret dex-admin (читать: kubectl get secret).
resource "random_password" "dex_admin_password" {
  count   = var.install_dex && var.sso_admin_password == "" ? 1 : 0
  length  = 24
  special = false
}

resource "random_uuid" "dex_admin_user_id" {
  count = var.install_dex ? 1 : 0
}

locals {
  dex_admin_password = var.sso_admin_password != "" ? var.sso_admin_password : one(random_password.dex_admin_password[*].result)
}

resource "kubernetes_namespace_v1" "dex" {
  count = var.install_dex ? 1 : 0

  metadata {
    name = "dex"
  }
}

# Полный конфиг dex (config.yaml): рендер из шаблона, секретные поля — из
# random_password. State в .gitignore; в репо секрета нет.
resource "kubernetes_secret_v1" "dex_config" {
  count = var.install_dex ? 1 : 0

  metadata {
    name      = "dex-config"
    namespace = kubernetes_namespace_v1.dex[0].metadata[0].name
  }

  data = {
    "config.yaml" = templatefile("../../addons/dex/manifests/config.yaml.tpl", {
      issuer                  = "https://${local.auth_hostname}"
      admin_email             = var.sso_admin_email
      admin_bcrypt            = bcrypt(local.dex_admin_password)
      admin_user_id           = random_uuid.dex_admin_user_id[0].result
      openwebui_client_secret = random_password.dex_client_secret_openwebui[0].result
      litellm_client_secret   = random_password.dex_client_secret_litellm[0].result
      n8n_client_secret       = random_password.dex_client_secret_n8n[0].result
      # пусто при install_observability=false (клиент grafana в dex не рендерится)
      grafana_client_secret = var.install_observability ? random_password.observability_grafana_oauth[0].result : ""
      osd_client_secret     = var.install_observability ? random_password.observability_osd_oauth[0].result : ""
      chat_hostname         = local.chat_hostname
      grafana_hostname      = local.grafana_hostname
      n8n_hostname          = local.n8n_hostname
      litellm_hostname      = local.litellm_hostname
      osd_hostname          = local.osd_hostname
    })
  }
}

# Пароль админа — в отдельном секрете (для чтения админом; в конфиге — только bcrypt-хэш)
resource "kubernetes_secret_v1" "dex_admin" {
  count = var.install_dex ? 1 : 0

  metadata {
    name      = "dex-admin"
    namespace = kubernetes_namespace_v1.dex[0].metadata[0].name
  }

  data = {
    password = local.dex_admin_password
  }
}

resource "helm_release" "dex" {
  count = var.install_dex ? 1 : 0

  name       = "dex"
  repository = "https://charts.dexidp.io"
  chart      = "dex"
  version    = var.dex_chart_version
  namespace  = kubernetes_namespace_v1.dex[0].metadata[0].name

  values = [
    file("../../addons/dex/values-selectel-mks.yaml"),
    yamlencode({
      # Рестарт пода при смене пароля админа: secret обновляется, но dex
      # читает конфиг только на старте. Чексумма — от ПАРОЛЯ (стабилен в
      # state), не от хэша bcrypt: bcrypt() даёт новую соль на каждый plan,
      # иначе под рестартовал бы на каждом apply.
      podAnnotations = {
        "config-checksum" = sha256(local.dex_admin_password)
      }
    }),
  ]

  depends_on = [kubernetes_secret_v1.dex_config]
}

# Client-секреты в ns панелей: панели берут их через secretKeyRef
# (n8n-клиент потребляет Envoy SecurityPolicy перед HTTPRoute n8n).
# depends_on обязателен: ns n8n создаёт helm-релиз (create_namespace),
# без явной зависимости секрет создавался раньше namespace (гонка на
# свежем кластере — "namespaces \"n8n\" not found").
resource "kubernetes_secret_v1" "dex_client" {
  for_each = var.install_dex ? toset(["openwebui", "litellm", "n8n"]) : toset([])

  metadata {
    name      = "dex-${each.key}-client"
    namespace = each.key
  }

  data = {
    "client-secret" = each.key == "openwebui" ? random_password.dex_client_secret_openwebui[0].result : (
      each.key == "litellm" ? random_password.dex_client_secret_litellm[0].result : random_password.dex_client_secret_n8n[0].result
    )
  }

  depends_on = [kubernetes_namespace_v1.openwebui, kubernetes_namespace_v1.litellm, helm_release.n8n]
}

# HTTPRoute dex (CRD — рендер + kubectl): публичный https://auth.<домен>
resource "local_file" "httproute_dex" {
  count = var.install_dex ? 1 : 0

  content = templatefile("../../addons/dex/manifests/httproute-dex.yaml.tpl", {
    auth_hostname = local.auth_hostname
  })

  filename        = "rendered/httproute-dex.yaml"
  file_permission = "0644"
}

# HTTPRoute n8n (CRD — рендер + kubectl): публичный https://n8n.<домен>
resource "local_file" "httproute_n8n" {
  count = var.install_n8n ? 1 : 0

  content = templatefile("../../addons/n8n/manifests/httproute-n8n.yaml.tpl", {
    n8n_hostname = local.n8n_hostname
  })

  filename        = "rendered/httproute-n8n.yaml"
  file_permission = "0644"
}

# HTTPRoute openwebui (CRD — рендер + kubectl): публичный https://chat.<домен>
resource "local_file" "httproute_openwebui" {
  count = var.install_openwebui ? 1 : 0

  content = templatefile("../../addons/openwebui/manifests/httproute-openwebui.yaml.tpl", {
    chat_hostname = local.chat_hostname
  })

  filename        = "rendered/httproute-openwebui.yaml"
  file_permission = "0644"
}

# SecurityPolicy OIDC для n8n (CRD envoy-gateway — рендер + kubectl):
# n8n Community не поддерживает OIDC, аутентификацию выполняет Envoy.
resource "local_file" "securitypolicy_n8n" {
  count = var.install_dex && var.install_n8n ? 1 : 0

  content = templatefile("../../addons/dex/manifests/securitypolicy-n8n.yaml.tpl", {
    auth_hostname = local.auth_hostname
    n8n_hostname  = local.n8n_hostname
  })

  filename        = "rendered/securitypolicy-n8n.yaml"
  file_permission = "0644"
}

# PROXY_ADMIN_ID для LiteLLM = email dex-админа (при GENERIC_USER_ID_ATTRIBUTE=email
# LiteLLM берёт user_id из OIDC-клейма email) — админ повышается при первом
# SSO-входе автоматически (проверено по исходникам ui_sso.py, v1.85+).
resource "kubernetes_secret_v1" "litellm_sso_admin" {
  count = var.install_dex && var.install_litellm ? 1 : 0

  metadata {
    name      = "litellm-proxy-admin-id"
    namespace = "litellm"
  }

  data = {
    "proxy-admin-id" = var.sso_admin_email
  }

  depends_on = [kubernetes_namespace_v1.litellm]
}

# Единый пароль админа (email+password) в ns панелей: потребляют init-jobs
# (OpenWebUI signup, n8n owner/setup). Один пароль — единый вход во все панели
# вместе с dex (см. addons/dex/README.md).
resource "kubernetes_secret_v1" "sso_admin" {
  for_each = var.install_dex ? toset(["openwebui", "n8n"]) : toset([])

  metadata {
    name      = "sso-admin"
    namespace = each.key
  }

  data = {
    email    = var.sso_admin_email
    password = local.dex_admin_password
  }

  # ns n8n создаёт helm-релиз (create_namespace) — без зависимости гонка
  # на свежем кластере ("namespaces \"n8n\" not found")
  depends_on = [kubernetes_namespace_v1.openwebui, helm_release.n8n]
}

# Индикатор смены пароля админа — пересоздаёт init-jobs ниже (Job с
# завершённым статусом не перезапускается сам).
resource "terraform_data" "sso_admin_password_version" {
  input = local.dex_admin_password
}

# Init-job OpenWebUI: создаёт админа (первый пользователь) декларативно —
# без ручного входа в UI. Манифест: addons/openwebui/manifests/job-init-admin.yaml
resource "kubernetes_manifest" "openwebui_init_admin" {
  count = var.install_dex && var.install_openwebui ? 1 : 0

  manifest = yamldecode(file("../../addons/openwebui/manifests/job-init-admin.yaml"))

  # Job-контроллер дописывает labels в pod-template (controller-uid и пр.) —
  # иначе провайдер ругается «inconsistent result after apply»
  computed_fields = ["metadata.labels", "spec.template.metadata.labels"]

  lifecycle {
    replace_triggered_by = [terraform_data.sso_admin_password_version]
  }

  depends_on = [helm_release.openwebui, kubernetes_secret_v1.sso_admin]
}

# Init-job n8n: инициализирует owner (POST /rest/owner/setup) декларативно.
# Манифест: addons/n8n/manifests/job-init-owner.yaml
resource "kubernetes_manifest" "n8n_init_owner" {
  count = var.install_dex && var.install_n8n ? 1 : 0

  manifest = yamldecode(file("../../addons/n8n/manifests/job-init-owner.yaml"))

  computed_fields = ["metadata.labels", "spec.template.metadata.labels"]

  lifecycle {
    replace_triggered_by = [terraform_data.sso_admin_password_version]
  }

  depends_on = [helm_release.n8n, kubernetes_secret_v1.sso_admin]
}

# --- csi-s3: монтирование S3-контейнера с весами (geesefs) --------------------
# Чарт k8s-csi-s3 (Yandex, общий S3-драйвер: любой S3-эндпоинт, mounter geesefs).
# Доки: addons/models/README.md. StorageClass csi-s3 монтирует весь контейнер
# (singleBucket) — маппинг моделей по имени каталога.

resource "helm_release" "csi_s3" {
  count = var.install_csi_s3 ? 1 : 0

  name       = "csi-s3"
  repository = "https://yandex-cloud.github.io/k8s-csi-s3/charts"
  chart      = "csi-s3"
  version    = var.csi_s3_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    secret = {
      accessKey = local.s3_access_key
      secretKey = local.s3_secret_key
      endpoint  = local.s3_endpoint
    }
    storageClass = {
      create       = true
      name         = "csi-s3"
      singleBucket = var.s3_bucket_name
      mounter      = "geesefs"
      # mmap-доступ к safetensors: geesefs держит кэш на ноде; 2000 МБ —
      # под модели 16-65 ГБ (дефолт 1000 МБ маловат для 32B)
      mountOptions  = "--memory-limit 2000 --dir-mode 0777 --file-mode 0666"
      reclaimPolicy = "Retain" # удаление PVC не удаляет веса в контейнере
    }
  })]
}

# --- Job: загрузка весов моделей из HuggingFace в S3 --------------------------
# Индикатор изменения списка моделей: recreation-триггер job'ы ниже.
# Креды S3 job'у не нужны: он пишет через PVC (geesefs сам ходит в S3
# с секретом csi-s3 из kube-system).

resource "terraform_data" "hf_models_version" {
  input = jsonencode(var.hf_models)
}

# Job spec immutable: смена токена меняет env → без этого триггера terraform
# пытался бы обновить Job на месте и падал. Хэш, а не сам токен — чтобы не
# дублировать секрет в state второй раз (он уже в kubernetes_secret_v1.hf_token).
resource "terraform_data" "hf_token_version" {
  input = sha256(var.huggingface_token)
}

# Токен HF для job'ы (env HF_TOKEN): без него анонимная загрузка ловит
# rate-limit. В Secret, а не в манифест Job — токен не должен попадать
# в terraform state как часть манифеста и в kubectl describe job.
resource "kubernetes_secret_v1" "hf_token" {
  count = var.huggingface_token != "" ? 1 : 0

  metadata {
    name      = "hf-token"
    namespace = "default"
  }

  data = {
    token = var.huggingface_token
  }
}

resource "kubernetes_manifest" "hf_models_upload" {
  count = var.install_csi_s3 && length(var.hf_models) > 0 ? 1 : 0

  manifest = yamldecode(templatefile("../../addons/models/job-hf-download.yaml.tpl", {
    models_csv   = join(",", [for alias, repo in var.hf_models : "${repo}=${alias}"])
    has_hf_token = var.huggingface_token != ""
  }))

  # Готовый Job не перезапускается: смена списка моделей или токена —
  # пересоздание. computed_fields: job-контроллер мутирует labels pod-template
  # — иначе провайдер падает «inconsistent result after apply»
  computed_fields = ["metadata.labels", "spec.template.metadata.labels"]

  lifecycle {
    replace_triggered_by = [terraform_data.hf_models_version, terraform_data.hf_token_version]
  }

  depends_on = [kubernetes_manifest.models_pvc]
}

# --- Observability: Prometheus + Grafana + OpenSearch + Fluent Bit ----------
# Umbrella-чарт addons/observability/chart (апстрим: selectel/inference-ready-
# mks-cluster, папка ai-ml-observability + наши дополнения: ServiceMonitor'ы
# litellm/aibrix/dcgm, дашборды litellm/dcgm/cnpg/n8n/aibrix, алерты,
# OIDC-Grafana через dex, паблик grafana.<домен>).
# CRD OpenSearch лежат в chart/crds (helm ставит при install; upgrade CRD не
# обновляет — известное ограничение helm, см. addons/observability/README.md).

resource "kubernetes_namespace_v1" "observability" {
  count = var.install_observability ? 1 : 0

  metadata {
    name = "monitoring"
  }
}

# Пароли: OpenSearch admin/дашборд-пользователь, Grafana admin и
# OIDC client_secret (общий с dex: staticClient grafana).
resource "random_password" "observability_opensearch_admin" {
  count   = var.install_observability ? 1 : 0
  length  = 24
  special = false # opensearch-плагин безопасности не принимает все спецсимволы
}

resource "random_password" "observability_opensearch_dashboard" {
  count   = var.install_observability ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "observability_grafana_admin" {
  count   = var.install_observability ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "observability_osd_oauth" {
  count   = var.install_observability ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "observability_grafana_oauth" {
  count   = var.install_observability ? 1 : 0
  length  = 32
  special = false
}

# Secret с OIDC client_secret Grafana (общий с dex staticClient grafana)
resource "kubernetes_secret_v1" "observability_grafana_oauth" {
  count = var.install_observability ? 1 : 0

  metadata {
    name      = "grafana-oauth"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }

  data = {
    client-secret = random_password.observability_grafana_oauth[0].result
  }
}

resource "helm_release" "observability" {
  count = var.install_observability ? 1 : 0

  name      = "monitoring"
  chart     = "../../addons/observability/chart"
  namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  timeout   = 1200

  # Скачивает сабчарты (Chart.yaml dependencies) в charts/ перед установкой
  dependency_update = true

  values = [
    file("../../addons/observability/values-selectel-mks.yaml"),
    # Секреты и zone-зависимые значения — вторым файлом (в state, не в репо)
    yamlencode({
      opensearch = {
        credentials = {
          adminPassword         = random_password.observability_opensearch_admin[0].result
          dashboardUserPassword = random_password.observability_opensearch_dashboard[0].result
        }
        oidc = {
          enabled         = var.install_dex ? true : false
          connectUrl      = "https://${local.auth_hostname}/.well-known/openid-configuration"
          clientId        = "opensearch-dashboards"
          clientSecret    = var.install_dex ? random_password.observability_osd_oauth[0].result : ""
          baseRedirectUrl = "https://${local.osd_hostname}"
        }
      }
      "kube-prometheus-stack" = {
        grafana = {
          adminPassword = random_password.observability_grafana_admin[0].result
          "grafana.ini" = {
            server = { root_url = "https://${local.grafana_hostname}/" }
            "auth.generic_oauth" = {
              auth_url  = "https://${local.auth_hostname}/auth"
              token_url = "https://${local.auth_hostname}/token"
              api_url   = "https://${local.auth_hostname}/userinfo"
            }
          }
        }
        prometheus = {
          prometheusSpec = {
            storageSpec = { volumeClaimTemplate = { spec = { storageClassName = var.storage_class_name } } }
          }
        }
        alertmanager = {
          alertmanagerSpec = {
            storage = { volumeClaimTemplate = { spec = { storageClassName = var.storage_class_name } } }
          }
        }
      }
    }),
  ]

  set = [
    {
      name  = "kube-prometheus-stack.grafana.persistence.storageClassName"
      value = var.storage_class_name
    },
    {
      name  = "opensearch.storage.className"
      value = var.storage_class_name
    },
  ]

  # Grafana-OIDC требует dex; env GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET — из
  # Secret grafana-oauth (создан до установки, иначе под Grafana падает)
  depends_on = [helm_release.dex, kubernetes_secret_v1.observability_grafana_oauth]
}

# Копия master-key litellm в ns monitoring: /metrics закрыт авторизацией,
# Prometheus читает секреты только своей namespace (см. ServiceMonitor litellm)
resource "kubernetes_secret_v1" "litellm_masterkey_monitoring" {
  count = var.install_litellm && var.install_observability ? 1 : 0

  metadata {
    name      = "litellm-masterkey"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }

  data = {
    masterkey = random_password.litellm_master_key[0].result
  }
}

# Пароль n8n-db для Grafana (SQL-дашборд grafana.com/24475): копия секрета
# оператора CNPG в ns monitoring (Prometheus/Grafana читают только свою ns).
# ЛОКАЛЬНОЕ ОГРАНИЧЕНИЕ (bootstrap): секрет n8n-db-app создаёт оператор CNPG
# только ПОСЛЕ ручного kubectl apply rendered/cnpg-clusters.yaml, поэтому на
# первом apply свежего кластера пароль ещё не читается (null) — секрет-копия
# создаётся любым следующим apply после поднятия кластеров БД. Без guard
# первый apply падал бы на null-index при чтении отсутствующего секрета.
data "kubernetes_secret_v1" "n8n_db" {
  count = var.install_n8n && var.install_observability ? 1 : 0

  metadata {
    name      = "n8n-db-app"
    namespace = "n8n"
  }
}

locals {
  # null, пока кластер n8n-db не создан и секрет оператора не существует
  n8n_db_password = try(data.kubernetes_secret_v1.n8n_db[0].data["password"], null)
}

resource "kubernetes_secret_v1" "n8n_db_monitoring" {
  count = var.install_n8n && var.install_observability && local.n8n_db_password != null ? 1 : 0

  metadata {
    name      = "n8n-db-readonly"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }

  data = {
    password = local.n8n_db_password
  }

  depends_on = [kubernetes_namespace_v1.observability]
}

# HTTPRoute grafana (CRD — рендер + kubectl): публичный https://grafana.<домен>
resource "local_file" "httproute_grafana" {
  count = var.install_observability ? 1 : 0

  content = templatefile("../../addons/observability/manifests/httproute-grafana.yaml.tpl", {
    grafana_hostname = local.grafana_hostname
  })

  filename        = "rendered/httproute-grafana.yaml"
  file_permission = "0644"
}

# HTTPRoute OpenSearch Dashboards (CRD — рендер + kubectl): osd.<домен>
resource "local_file" "httproute_osd" {
  count = var.install_observability ? 1 : 0

  content = templatefile("../../addons/observability/manifests/httproute-osd.yaml.tpl", {
    osd_hostname = local.osd_hostname
  })

  filename        = "rendered/httproute-osd.yaml"
  file_permission = "0644"
}
