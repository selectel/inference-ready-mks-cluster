# =============================================================================
# Домен и DNS (опционально). Создание зоны/пользователя активно при ОДНОВРЕМЕННОМ
# выполнении в blueprint.tfvars:
#   1) create_zone_and_user = true   # дефолт: этот terraform создаёт зону и
#      сервисного пользователя (аккаунт кластера, проект кластера);
#   2) dns_zone_name не пуст (достаточно имени домена, пароль сгенерится сам);
#   3) включён install_cert_manager или install_external_dns (02-корень) —
#      если оба DNS-аддона выключены, зону/пользователя создавать не зачем.
#
# Если create_zone_and_user = false — зона и пользователь УЖЕ существуют (любой
# аккаунт Selectel): креды передаются в 02-addons переменными dns_* (см. README).
# Тумблеры при этом в создании не участвуют — 01-корень ничего не создаёт.
#
# Что тут есть и чего нет:
#   - РЕГИСТРАЦИЮ (покупку) домена terraform'ом сделать нельзя — у провайдера
#     Selectel нет такого ресурса. Домен покупается в панели управления
#     (Продукты → Домены, зоны .ru/.рф): https://docs.selectel.ru/domains/
#   - ЗОНА в DNS-хостинге (actual) создаётся terraform'ом (domains_zone_v2).
#     Домен должен быть делегирован на NS Selectel: при покупке в Selectel —
#     автоматически, со стороннего регистратора — NS-записи меняются руками
#     (a.ns.selectel.ru … d.ns.selectel.ru): https://docs.selectel.ru/dns-hosting/
#   - Сервисный пользователь dns (member в проекте) — для cert-manager
#     и external-dns: DNS API Selectel требует project-scoped токен.
# =============================================================================

locals {
  # API требует FQDN с точкой в конце; принимаем и "example.com", и "example.com."
  dns_zone_fqdn = var.dns_zone_name == "" ? "" : "${trimsuffix(var.dns_zone_name, ".")}."

  # Зону и dns-пользователя создаём ТОЛЬКО когда все три условия:
  #   1. create_zone_and_user = true       (вариант 1, терраформ управляет)
  #   2. dns_zone_name не пуст (пусто — DNS-секция неактивна)
  #   3. Хоть один DNS-аддон включён в 02-корне (иначе создавать не зачем)
  create_dns_core = var.create_zone_and_user && var.dns_zone_name != "" && (var.install_cert_manager || var.install_external_dns)
}

# Пароль генерируем (креды уезжают в кластер только в Secret'ы вебхуков
# cert-manager/external-dns, ротация не задевает service-пользователя OpenStack).
resource "random_password" "dns_user" {
  count = local.create_dns_core ? 1 : 0

  length  = 24
  special = true
  # без кавычек/бэкслэшей — дружелюбно к helm/k8s-подстановкам
  override_special = "!#$%*+-=?@^_"
}

resource "selectel_iam_serviceuser_v1" "dns_user" {
  count = local.create_dns_core ? 1 : 0

  name     = "${var.project_name}-dns"
  password = random_password.dns_user[0].result

  role {
    role_name  = "member" # DNS API авторизует project-scoped токеном
    scope      = "project"
    project_id = selectel_vpc_project_v2.project_1.id
  }
}

# Зона в DNS-хостинге (actual). NS/SOA-записи создаются автоматически
# (a.ns.selectel.ru … d.ns.selectel.ru) — их нельзя редактировать/удалять.
resource "selectel_domains_zone_v2" "dns_zone" {
  count = local.create_dns_core ? 1 : 0

  # Alias-провайдер: провайдер ищет endpoint сервиса dnsv2 в keystone-каталоге
  # по auth_region, а в ru-6 этого endpoint НЕТ (проверено по каталогу; dnsv2
  # есть в ru-1/2/3/7/8/9). Сам DNS API глобальный (api.selectel.ru/domains/v2),
  # поэтому регион здесь — лишь способ найти endpoint в каталоге.
  provider = selectel.dns

  name       = local.dns_zone_fqdn
  project_id = selectel_vpc_project_v2.project_1.id
}
