# --- Подключение к кластеру ---

variable "kubeconfig_path" {
  description = "Путь к kubeconfig кластера (output kubeconfig_path из 01-cluster)."
  type        = string
}

variable "cluster_id" {
  description = "ID кластера MKS (output cluster_id из 01-cluster). Обязателен для Karpenter."
  type        = string
}

# --- Тумблеры компонентов: указывайте в terraform.tfvars, что ставить ---

variable "install_karpenter" {
  description = "Установить Karpenter (автоскейлер нод, helm-чарт Selectel). Требует cluster_id и cluster без включённого автоскейлинга/автовосстановления."
  type        = bool
  default     = true
}

variable "install_envoy_gateway" {
  description = "Установить Envoy Gateway (обязательная зависимость LLM-шлюза AIBrix; официальный путь Selectel для Gateway API)."
  type        = bool
  default     = true
}

variable "install_aibrix" {
  description = "Установить AIBrix (контроль-плейн LLM-инференса: routing, autoscaling, LoRA, metadata). Требует install_envoy_gateway = true."
  type        = bool
  default     = true
}

variable "deploy_models" {
  description = "Модели vLLM через чарт inference-charts (terraform ставит helm-релизы; веса — из S3, требует install_csi_s3 и запись в hf_models с алиасом = каталогу весей). Ключ — имя модели (= serviceName = --served-model-name, инвариант AIBrix); preset — файл addons/inference-charts/values-<preset>.yaml (существующие: deepseek-r1-distill-llama-8b-s3, qwen3-32b-s3); values — точечные переопределения поверх пресета (yamlencode)."
  type = map(object({
    preset = optional(string)
    values = optional(map(any))
  }))
  default = {
    # Дефолт: лёгкая модель для smoke-теста кластера (L4/RTX 4090).
    # Ключ = имя модели (= --served-model-name); алиас в hf_models должен
    # совпадать с каталогом весей в S3 (modelPath пресета).
    "deepseek-r1-distill-llama-8b" = {
      preset = "deepseek-r1-distill-llama-8b-s3"
    }
  }

  validation {
    condition = alltrue([
      for n, m in var.deploy_models : m.preset == null || fileexists("${path.module}/../../addons/inference-charts/values-${m.preset}.yaml")
    ])
    error_message = "deploy_models: preset не существует (ждём addons/inference-charts/values-<preset>.yaml)."
  }

  validation {
    condition     = length(var.deploy_models) == 0 || var.install_csi_s3
    error_message = "deploy_models требует install_csi_s3: деплой моделей всегда идёт с весами из S3 (PVC models)."
  }
}

variable "install_litellm" {
  description = "Установить LiteLLM Proxy (auth-слой: virtual keys, бюджеты, лимиты перед AIBrix)."
  type        = bool
  default     = true
}

variable "install_openwebui" {
  description = "Установить OpenWebUI (веб-морда чата, чарт helm.openwebui.com). Бэкенд LLM — LiteLLM (требует install_litellm). Требует storage_class_name."
  type        = bool
  default     = true

  validation {
    condition     = !var.install_openwebui || var.install_litellm
    error_message = "install_openwebui требует install_litellm: OPENAI_API_KEY берётся из секрета litellm-masterkey."
  }
}

variable "install_n8n" {
  description = "Установить n8n (автоматизации, community-чарт community-charts.github.io). Требует storage_class_name."
  type        = bool
  default     = true
}

variable "install_gpu_operator" {
  description = "Установить NVIDIA GPU Operator в classic-режиме (драйвер + device plugin nvidia.com/gpu + DCGM). Единственный рабочий путь GPU в этой конфигурации репо: SelectelNodeClass создан с installNvidiaDevicePlugin=false (без оператора ни classic-реквесты nvidia.com/gpu, ни DRA-claim'ы не работают — драйвера на нодах нет). Требует Karpenter. Доки/грабли: addons/gpu-operator/README.md."
  type        = bool
  default     = true
}

# --- Хранилище и БД прикладных сервисов (prod) ---

variable "install_cnpg" {
  description = "Установить CloudNativePG (оператор PostgreSQL) и отрендерить кластеры litellm-db / n8n-db / openwebui-db (применяются kubectl: rendered/cnpg-clusters.yaml). Доки: addons/cnpg/README.md."
  type        = bool
  default     = true
}

variable "install_valkey" {
  description = "Установить Valkey (общий redis-совместимый кэш/очередь для litellm/n8n/openwebui, чарт bitnami). Доки: addons/valkey/README.md."
  type        = bool
  default     = true
}

variable "install_dex" {
  description = "Установить dex (SSO/OIDC для веб-панелей: OpenWebUI, LiteLLM UI; n8n — через Envoy SecurityPolicy). Требует dns_zone_name, install_cert_manager/install_external_dns и sso_admin_email. Доки: addons/dex/README.md."
  type        = bool
  default     = true

  validation {
    condition     = !var.install_dex || (var.dns_zone_name != "" && var.install_cert_manager && var.install_external_dns)
    error_message = "install_dex требует dns_zone_name, install_cert_manager и install_external_dns (публичный https://auth.<домен>)."
  }
}

variable "install_csi_s3" {
  description = "Установить csi-s3 (geesefs): монтирование S3-контейнера с весами моделей в поды (StorageClass csi-s3, singleBucket). Требует s3_bucket_name и креды (create_object_storage в 01-корне или s3_access_key/s3_secret_key ниже)."
  type        = bool
  default     = true
}

variable "cnpg_instances" {
  description = "Инстансов в каждом кластере CNPG (2 = primary + реплика)."
  type        = number
  default     = 2
}

variable "cnpg_storage_size" {
  description = "Размер PV кластера CNPG."
  type        = string
  default     = "10Gi"
}

variable "hf_models" {
  description = "Веса моделей для загрузки из HuggingFace в S3: map алиас (каталог в контейнере = --model /models/<алиас>) → repo_id. Изменение пересоздаёт Job (kubectl -n models)."
  type        = map(string)
  default = {
    deepseek-r1-distill-llama-8b = "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
  }

  validation {
    condition     = !var.install_csi_s3 || length(var.hf_models) > 0
    error_message = "hf_models обязателен при install_csi_s3 (job загрузки весов)."
  }
}

variable "huggingface_token" {
  description = "Токен HuggingFace для job'ы загрузки весов (env HF_TOKEN из Secret hf-token): убирает rate-limit анонимной загрузки. Пусто — анонимно. Смена токена пересоздаёт Job."
  type        = string
  default     = ""
  sensitive   = true
}

# --- S3: креды контейнера (создан в 01-корне при create_object_storage=true) ---

variable "create_object_storage" {
  description = "Контейнер S3 и ключи созданы terraform'ом 01-корня — креды приходят из его state (terraform_remote_state). false — заполнить s3_* ниже (контейнер создан вручную/в панели)."
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "Имя S3-контейнера с весами моделей (должен существовать; создаётся 01-корнём при create_object_storage=true). Дефолт совпадает с дефолтом 01-корня."
  type        = string
  default     = "inference-models"

  validation {
    condition     = !var.install_csi_s3 || var.s3_bucket_name != ""
    error_message = "s3_bucket_name обязателен при install_csi_s3."
  }
}

variable "s3_access_key" {
  description = "Access Key S3 (только при create_object_storage=false)."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.create_object_storage || !(var.install_csi_s3) || var.s3_access_key != ""
    error_message = "s3_access_key обязателен при install_csi_s3 и create_object_storage=false."
  }
}

variable "s3_secret_key" {
  description = "Secret Key S3 (только при create_object_storage=false)."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.create_object_storage || !(var.install_csi_s3) || var.s3_secret_key != ""
    error_message = "s3_secret_key обязателен при install_csi_s3 и create_object_storage=false."
  }
}

variable "s3_endpoint" {
  description = "Домен S3 API (только при create_object_storage=false; напр. https://s3.ru-6.storage.selcloud.ru)."
  type        = string
  default     = ""

  validation {
    condition     = var.create_object_storage || !var.install_csi_s3 || var.s3_endpoint != ""
    error_message = "s3_endpoint обязателен при install_csi_s3 и create_object_storage=false."
  }
}

# --- SSO (dex) ---

variable "sso_admin_email" {
  description = "Email админ-пользователя dex (локальная парольная БД; пароль генерируется и кладётся в Secret dex-admin). Первый вход этого пользователя в OpenWebUI получает права администратора."
  type        = string
  default     = ""

  validation {
    condition     = !var.install_dex || var.sso_admin_email != ""
    error_message = "sso_admin_email обязателен при install_dex."
  }
}

variable "sso_admin_password" {
  description = "Пароль админа dex. Пусто — генерируется (Secret dex-admin, читать kubectl)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_bucket_name" {
  description = "Имя S3-контейнера бэкапов CNPG — актуально только при create_object_storage=false (иначе берётся из state 01-корня)."
  type        = string
  default     = ""
}

variable "storage_class_name" {
  description = "Имя StorageClass для PVC OpenWebUI/n8n (имя зависит от региона, см. `kubectl get storageclass`, напр. fast2.ru-6). Обязателен при install_openwebui или install_n8n."
  type        = string
  default     = ""

  validation {
    condition     = !(var.install_openwebui || var.install_n8n) || var.storage_class_name != ""
    error_message = "storage_class_name обязателен при install_openwebui/install_n8n (у кластера нет default StorageClass)."
  }
}

variable "install_cert_manager" {
  description = "Установить cert-manager + Selectel DNS01-webhook (TLS-сертификаты Let's Encrypt через DNS-хостинг Selectel). Требует dns_zone_name, letsencrypt_email и креды dns-пользователя из 01-cluster."
  type        = bool
  default     = true
}

variable "install_external_dns" {
  description = "Установить external-dns с Selectel-вебхуком (автосоздание DNS-записей для Service/Ingress в зоне dns_zone_name). Требует dns_zone_name и креды dns-пользователя из 01-cluster."
  type        = bool
  default     = true
}

# --- Домен и DNS (опция: зона и пользователь уже существуют; 02-addons) ---
# Схема выбора — в blueprint.tfvars (переменная create_zone_and_user, см. 01-cluster):
#   true (дефолт): 01-cluster сам создал зону и dns-пользователя — креды
#     приходят из state 01-корня (terraform_remote_state), здесь указываете только dns_zone_name.
#   false: зона/пользователь уже существуют (любой аккаунт) — заполняете ниже все dns_*.
# Переменные ниже нужны только при install_cert_manager / install_external_dns.

variable "create_zone_and_user" {
  description = "Зона и dns-пользователь созданы terraform'ом 01-корня (креды — из его state). false — существующие (заполнить dns_* ниже)."
  type        = bool
  default     = true
}

variable "dns_zone_name" {
  description = "Имя домена (зоны DNS), например example.com. Обязательно при install_cert_manager / install_external_dns."
  type        = string
  default     = ""

  validation {
    condition     = !(var.install_cert_manager || var.install_external_dns) || var.dns_zone_name != ""
    error_message = "dns_zone_name обязателен при install_cert_manager или install_external_dns."
  }
}

variable "dns_user_name" {
  description = "Существующий сервисный пользователь DNS (только при create_zone_and_user=false)."
  type        = string
  default     = ""

  validation {
    condition     = var.create_zone_and_user || !(var.install_cert_manager || var.install_external_dns) || var.dns_user_name != ""
    error_message = "dns_user_name обязателен при create_zone_and_user=false и включённых install_cert_manager/install_external_dns."
  }
}

variable "dns_user_password" {
  description = "Пароль существующего сервисного пользователя DNS (только при create_zone_and_user=false)."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.create_zone_and_user || !(var.install_cert_manager || var.install_external_dns) || length(var.dns_user_password) >= 8
    error_message = "dns_user_password обязателен при create_zone_and_user=false и включённых install_cert_manager/install_external_dns."
  }
}

variable "dns_account_id" {
  description = "ID учётной записи, где живёт зона (только при create_zone_and_user=false; нужен вебхукам для keystone-аутентификации)."
  type        = string
  default     = ""

  validation {
    condition     = var.create_zone_and_user || !(var.install_cert_manager || var.install_external_dns) || var.dns_account_id != ""
    error_message = "dns_account_id обязателен при create_zone_and_user=false и включённых install_cert_manager/install_external_dns."
  }
}

variable "dns_project_id" {
  description = "ID проекта, к которому привязана зона (только при create_zone_and_user=false)."
  type        = string
  default     = ""

  validation {
    condition     = var.create_zone_and_user || !(var.install_cert_manager || var.install_external_dns) || var.dns_project_id != ""
    error_message = "dns_project_id обязателен при create_zone_and_user=false и включённых install_cert_manager/install_external_dns."
  }
}

variable "letsencrypt_email" {
  description = "Email для ClusterIssuer Let's Encrypt (уведомления об истечении). Обязателен при install_cert_manager; попадает в отрендеренный манифест (kubectl apply, CRD — terraform'ом нельзя)."
  type        = string
  default     = ""

  validation {
    condition     = !var.install_cert_manager || var.letsencrypt_email != ""
    error_message = "letsencrypt_email обязателен при install_cert_manager."
  }
}

# --- Версии компонентов (пиннуты; поднимайте осознанно) ---

variable "karpenter_chart_version" {
  description = "Версия helm-чарта Selectel Karpenter (releases: github.com/selectel/mks-charts)."
  type        = string
  default     = "0.4.0"
}

variable "envoy_gateway_chart_version" {
  description = "Версия чарта Envoy Gateway (github.com/envoyproxy/gateway/releases)."
  type        = string
  default     = "v1.2.8"
}

variable "cert_manager_chart_version" {
  description = "Версия чарта cert-manager (charts.jetstack.io)."
  type        = string
  default     = "v1.21.1"
}

variable "cert_manager_webhook_chart_version" {
  description = "Версия чарта cert-manager-webhook-selectel (helm-репо selectel.github.io/cert-manager-webhook-selectel)."
  type        = string
  default     = "1.4.0"
}

variable "openwebui_chart_version" {
  description = "Версия чарта open-webui (helm.openwebui.com)."
  type        = string
  default     = "16.5.0"
}

variable "n8n_chart_version" {
  description = "Версия community-чарта n8n (community-charts.github.io/helm-charts)."
  type        = string
  default     = "1.24.40"
}

variable "cnpg_chart_version" {
  description = "Версия чарта cloudnative-pg (cloudnative-pg.github.io/charts)."
  type        = string
  default     = "0.29.0"
}

variable "valkey_chart_version" {
  description = "Версия чарта valkey (charts.bitnami.com/bitnami)."
  type        = string
  default     = "6.2.19"
}

variable "dex_chart_version" {
  description = "Версия чарта dex (charts.dexidp.io)."
  type        = string
  default     = "0.24.1"
}

variable "csi_s3_chart_version" {
  description = "Версия чарта csi-s3 (yandex-cloud.github.io/k8s-csi-s3/charts)."
  type        = string
  default     = "0.43.7"
}

variable "install_observability" {
  description = "Установить observability-стек (Prometheus + Grafana + Alertmanager, OpenSearch + Fluent Bit, ServiceMonitor'ы aibrix/litellm/CNPG/n8n/vLLM/DCGM, дашборды и базовые алерты). OIDC-Grafana через dex, паблик grafana.<домен>. Доки: addons/observability/README.md."
  type        = bool
  default     = true

  validation {
    condition     = !var.install_observability || (var.dns_zone_name != "" && var.install_dex)
    error_message = "install_observability требует dns_zone_name (публичный grafana.<домен>) и install_dex (OIDC-вход Grafana)."
  }
}
