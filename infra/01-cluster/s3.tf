# =============================================================================
# Объектное хранилище (S3): контейнер под веса моделей LLM.
#
# Контейнер создаётся через Swift API (openstack_objectstorage_container_v1):
# у Selectel S3 и Swift — один бэкенд, бакет, созданный любым из API, виден
# обоими. В terraform-провайдере Selectel ресурса «бакет S3» нет, а Swift-каталог
# (object-store) у project-пользователя в service catalog есть (проверено:
# https://swift.<pool>.storage.selcloud.ru/v1/<account_id>) — поэтому Swift-ресурс
# без новых провайдеров и без круговых зависимостей.
#
# Ключи доступа (S3 credentials) — отдельный ресурс: ключи выпускаются на
# сервисного пользователя проекта (selectel_iam_s3_credentials_v1). Значения
# уходят в sensitive-outputs → 02-addons читает их через terraform_remote_state.
# =============================================================================

# Контейнер (бакет) под веса моделей. Имя должно быть уникально в пуле.
resource "openstack_objectstorage_container_v1" "models" {
  count = var.create_object_storage ? 1 : 0

  name = var.s3_bucket_name

  # Удаление контейнера с весами — только осознанно (force_destroy=false:
  # terraform не удалит непустой контейнер). cleanup при destroy — вручную.
  force_destroy = false

  # Провайдер openstack уже сконфигурирован на var.region — ресурс попадает
  # в пул региона кластера.
}

# Отдельный контейнер под бэкапы CNPG (wal + data через barman-cloud).
# Отдельный от весов: другие политики хранения и удаление не мешает моделям.
resource "openstack_objectstorage_container_v1" "cnpg_backups" {
  count = var.create_object_storage ? 1 : 0

  name = var.backup_bucket_name

  force_destroy = false
}

# S3-ключи (Access/Secret Key) для доступа к хранилищу через S3 API.
# Владелец — сервисный пользователь проекта (project_user, роль member).
resource "selectel_iam_s3_credentials_v1" "s3_keys" {
  count = var.create_object_storage ? 1 : 0

  user_id    = selectel_iam_serviceuser_v1.project_user.id
  project_id = selectel_vpc_project_v2.project_1.id
  name       = "${var.cluster_name}-s3"
}

locals {
  # Домен S3 API зависит от пула: s3.<pool>.storage.selcloud.ru (формат из
  # ~/.s3cfg и docs.selectel.ru, «S3 tools / s3cmd»).
  s3_endpoint = "https://s3.${var.region}.storage.selcloud.ru"
}

output "s3_bucket_name" {
  description = "Имя контейнера S3 с весами моделей. Пусто, если create_object_storage=false."
  value       = var.create_object_storage ? var.s3_bucket_name : ""
}

output "s3_backup_bucket_name" {
  description = "Имя контейнера S3 под бэкапы CNPG. Пусто, если create_object_storage=false."
  value       = var.create_object_storage ? var.backup_bucket_name : ""
}

output "s3_endpoint" {
  description = "Домен S3 API пула региона (path-style)."
  value       = local.s3_endpoint
}

output "s3_access_key" {
  description = "Access Key S3 (для 02-addons: csi-s3, job загрузки весов). Пусто, если create_object_storage=false."
  value       = length(selectel_iam_s3_credentials_v1.s3_keys) == 0 ? "" : selectel_iam_s3_credentials_v1.s3_keys[0].access_key
  sensitive   = true
}

output "s3_secret_key" {
  description = "Secret Key S3 (для 02-addons: csi-s3, job загрузки весов). Пусто, если create_object_storage=false."
  value       = length(selectel_iam_s3_credentials_v1.s3_keys) == 0 ? "" : selectel_iam_s3_credentials_v1.s3_keys[0].secret_key
  sensitive   = true
}
