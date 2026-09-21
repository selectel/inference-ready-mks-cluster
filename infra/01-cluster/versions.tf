terraform {
  required_version = ">= 1.9.2"

  required_providers {
    selectel = {
      source  = "selectel/selectel"
      version = "~> 8.3"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

# Провайдер Selectel — учётная запись верхнего уровня (создаёт проект и пользователя).
provider "selectel" {
  username    = var.sel_username
  password    = var.sel_password
  domain_name = var.sel_domain_name
  # Начиная с провайдера 6.x обязательны:
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3/"
  auth_region = var.region
}

# DNS-хостинг — НЕ управляется этим корнем: зона и сервисный пользователь
# живут в отдельном Selectel-аккаунте (см. README «Домен и DNS»), их креды
# передаются в 02-addons переменными dns_* из blueprint.tfvars.

# Alias-провайдер только для DNS-хостинга (ресурсы в dns.tf): см. комментарий
# в dns.tf — в каталоге ru-6 нет endpoint'а dnsv2, поэтому регион ru-1.
provider "selectel" {
  alias       = "dns"
  username    = var.sel_username
  password    = var.sel_password
  domain_name = var.sel_domain_name
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3/"
  auth_region = "ru-1"
}

# Провайдер OpenStack — работает от имени пользователя ПРОЕКТА (создаёт сети).
provider "openstack" {
  auth_url            = var.auth_url
  user_name           = selectel_iam_serviceuser_v1.project_user.name
  password            = var.project_user_password
  tenant_name         = selectel_vpc_project_v2.project_1.name
  project_domain_name = var.sel_domain_name
  user_domain_name    = var.sel_domain_name
  region              = var.region
}
