# Маппинг типа сетевого диска (volume category) для terraform-корней
# infra/01-cluster, infra/02-addons и будущих.
#
# Источник: https://docs.selectel.ru/cloud-servers/volumes/about-network-volumes/
#
# В сегментах ru-6a/ru-6b/ru-6c нет типов universal и fast — там доступны
# только их версии v2: universal2 и fast2 (аналогично fast → fast2).
# Во всех остальных сегментах basic, universal и fast доступны везде,
# поэтому отдельная таблица по зонам не нужна — подстановка ru-6 задана явно.

variable "zone" {
  description = "Сегмент пула Selectel, например ru-7a или ru-6a."
  type        = string
}

variable "category" {
  description = "Желаемая категория диска: basic, universal или fast."
  type        = string
  default     = "universal"

  validation {
    condition     = contains(["basic", "universal", "fast"], var.category)
    error_message = "Допустимые категории диска: basic, universal, fast."
  }
}

locals {
  # Подстановки для зон без запрошенного типа (сегодня это только ru-6a/b/c).
  substitutes = startswith(var.zone, "ru-6") ? {
    universal = "universal2"
    fast      = "fast2"
  } : {}

  category = try(local.substitutes[var.category], var.category)
}

output "category" {
  description = "Категория диска, доступная в зоне: например universal2 для universal в ru-6."
  value       = local.category
}

output "volume_type" {
  description = "Готовый volume_type для selectel_mks_nodegroup_v1: <category>.<zone>, например universal2.ru-6a."
  value       = "${local.category}.${var.zone}"
}
