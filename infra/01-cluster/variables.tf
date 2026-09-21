# --- Учётная запись Selectel (верхний уровень, для провайдера selectel) ---

variable "sel_username" {
  description = "Имя пользователя учётной записи Selectel (обычно вида user123456)."
  type        = string
}

variable "sel_password" {
  description = "Пароль пользователя учётной записи Selectel."
  type        = string
  sensitive   = true
}

variable "sel_domain_name" {
  description = "ID учётной записи Selectel (виден в панели: Профиль → Информация об аккаунте)."
  type        = string
}

variable "auth_url" {
  description = "OpenStack Identity API endpoint."
  type        = string
  default     = "https://cloud.api.selcloud.ru/identity/v3"
}

# --- Проект и пользователь проекта ---

variable "project_name" {
  description = "Имя создаваемого проекта."
  type        = string
  default     = "inference-mks"
}

variable "project_user_name" {
  description = "Имя service-пользователя внутри проекта."
  type        = string
  default     = "tf-user"
}

variable "project_user_password" {
  description = "Пароль service-пользователя проекта (минимум 8 символов, буквы + цифры)."
  type        = string
  sensitive   = true
}

# --- Локация ---

variable "region" {
  description = "Пул размещения кластера, например ru-7. Доступность GPU зависит от пула: H100 — ru-7b, A100 40Gb — ru-7a/ru-9a, L4 — ru-6a/ru-7a (см. матрицу доступности Selectel)."
  type        = string
  default     = "ru-7"
}

variable "availability_zone" {
  description = "Сегмент пула для system-нодгруппы, например ru-7a. Должен принадлежать пулу var.region."
  type        = string
  default     = "ru-7a"
}

# --- Сеть ---

variable "subnet_cidr" {
  description = "CIDR приватной подсети кластера. Не должен пересекаться с 10.10.0.0/16, 10.96.0.0/12, 10.250.0.0/16, 10.251.0.0/24 (зарезервировано MKS)."
  type        = string
  default     = "192.168.0.0/24"
}

# --- Кластер MKS ---

variable "cluster_name" {
  description = "Имя кластера Managed Kubernetes."
  type        = string
  default     = "inference-mks"
}

variable "kube_version" {
  description = "Версия Kubernetes. Пустая строка = актуальная default-версия пула. Karpenter требует >= 1.28; MKS поддерживает 1.34–1.36."
  type        = string
  default     = ""
}

variable "maintenance_window_start" {
  description = "Начало технологического окна (UTC), формат hh:mm:ss. Например 04:00:00."
  type        = string
  default     = "04:00:00"
}

variable "enable_patch_version_auto_upgrade" {
  description = "Автообновление патч-версий кластера."
  type        = bool
  default     = true
}

# --- System-нодгруппа (CPU): для control-plane AIBrix и контроллера Karpenter ---

variable "system_nodes_count" {
  description = "Число нод system-группы. Karpenter требует >= 1 ноду (2 vCPU / 4 GiB); рекомендуем 2 — у чарта Karpenter podAntiAffinity."
  type        = number
  default     = 3
}

variable "system_cpus" {
  description = "vCPU нод system-группы."
  type        = number
  default     = 4
}

variable "system_ram_mb" {
  description = "RAM нод system-группы (МБ). AIBrix control-plane ~2.5 vCPU / 2.5 GiB + Envoy Gateway."
  type        = number
  default     = 8192
}

variable "system_volume_gb" {
  description = "Размер загрузочного диска system-нод (ГБ)."
  type        = number
  default     = 50
}

variable "system_volume_category" {
  description = "Тип загрузочного диска system-нод: basic, universal или fast. Модуль modules/disk-type подбирает доступный в зоне тип (в ru-6: universal → universal2, fast → fast2)."
  type        = string
  default     = "universal"
}

variable "keypair_name" {
  description = "Имя SSH-ключа для доступа к нодам (пусто = без ключа)."
  type        = string
  default     = ""
}

variable "cni_type" {
  description = "CNI кластера: CALICO или CILIUM. Выбирается при создании; смена на существующем кластере не проверена — скорее всего пересоздаст кластер."
  type        = string
  default     = "CALICO"

  validation {
    condition     = contains(["CALICO", "CILIUM"], var.cni_type)
    error_message = "cni_type должен быть CALICO или CILIUM."
  }
}

variable "kubeconfig_output_path" {
  description = "Куда записать kubeconfig кластера (для корня 02-addons)."
  type        = string
  default     = "kubeconfig"
}

# --- Объектное хранилище S3 (веса моделей; см. s3.tf) ---

variable "create_object_storage" {
  description = "true — создать контейнер S3 под веса моделей и S3-ключи (s3.tf). false — объектное хранилище не создаётся этим корнём (можно задать ключи в 02-addons вручную переменными s3_access_key/s3_secret_key)."
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "Имя контейнера S3 под веса моделей (уникально в пуле, 3–63 символа, строчные)."
  type        = string
  default     = "inference-models"
}

variable "backup_bucket_name" {
  description = "Имя контейнера S3 под бэкапы CNPG (барман: wal + снапшоты). Отдельный от контейнера весов."
  type        = string
  default     = "inference-cnpg-backups"
}

# --- Домен и DNS (опционально; используются только при включённых
# install_cert_manager / install_external_dns в 02-addons) ---

variable "create_zone_and_user" {
  description = "true (дефолт) — этот terraform создаёт зону DNS-хостинга и сервисного пользователя в аккаунте/проекте кластера (достаточно dns_zone_name; пароль генерируется). false — зона и пользователь уже существуют (любой аккаунт Selectel): креды передаются в 02-addons переменными dns_user_name/password/account_id/project_id. Регистрация домена и делегация NS — вручную в любом случае."
  type        = bool
  default     = true
}

variable "dns_zone_name" {
  description = "Имя домена (зоны DNS), например example.com. Пусто — DNS-секция неактивна. При create_zone_and_user=false зона с этим именем должна уже существовать в DNS-хостинге."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\\.?$", var.dns_zone_name))
    error_message = "dns_zone_name должен быть доменом вроде example.com (можно с конечной точкой) или пустым."
  }
}

# Тумблеры 02-корня (дублируются здесь из общего blueprint.tfvars, чтобы
# dns.tf не создавал зону/пользователя, когда DNS-аддоны всё равно не ставятся).
variable "install_cert_manager" {
  description = "Ставить cert-manager (02-addons). Влияет и на 01: включённый вместе с dns_zone_name — разрешает создание зоны/dns-пользователя."
  type        = bool
  default     = false
}

variable "install_external_dns" {
  description = "Ставить external-dns (02-addons). Влияет и на 01: включённый вместе с dns_zone_name — разрешает создание зоны/dns-пользователя."
  type        = bool
  default     = false
}
