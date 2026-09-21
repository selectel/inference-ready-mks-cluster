# =============================================================================
# Шаг 1: проект, service-пользователь, сеть, кластер MKS, system-нодгруппа.
# GPU-ноды создаёт Karpenter (шаг 2) — нодгруппы GPU в Terraform не нужны.
# =============================================================================

# --- Проект и service-пользователь проекта ---

resource "selectel_vpc_project_v2" "project_1" {
  name = var.project_name
}

resource "selectel_iam_serviceuser_v1" "project_user" {
  name     = var.project_user_name
  password = var.project_user_password

  # member — управление ресурсами проекта (сеть, кластер);
  # s3.admin — создание S3-контейнеров через Swift API (s3.tf). На 2026-09
  # роль member в scope проекта документирована как дающая доступ к S3,
  # но Swift API отдаёт 403 даже на листинг — работает только с s3.admin
  # (проверено на свежем проекте; вероятно, изменение модели доступа S3).
  role {
    role_name  = "member"
    scope      = "project"
    project_id = selectel_vpc_project_v2.project_1.id
  }

  role {
    role_name  = "s3.admin"
    scope      = "project"
    project_id = selectel_vpc_project_v2.project_1.id
  }
}

# --- Сеть: роутер с внешней сетью + приватная подсеть ---
# Паттерн из официальных примеров Selectel (terraform-examples, modules/cloud/nat).

data "openstack_networking_network_v2" "external_net" {
  name     = "external-network"
  external = true

  # Без depends_on data source читается на этапе plan, когда service-пользователь
  # ещё не создан — провайдер openstack аутентифицируется его кредами и падает
  # с "Authentication failed". depends_on переносит чтение на этап apply.
  # Управляемые openstack-ресурсы (router, network, subnet) в явной зависимости
  # не нуждаются: она уже есть через конфигурацию провайдера openstack,
  # который ссылается на project_user.name и project_1.name.
  depends_on = [selectel_iam_serviceuser_v1.project_user]
}

resource "openstack_networking_router_v2" "router_1" {
  name                = "${var.cluster_name}-router"
  external_network_id = data.openstack_networking_network_v2.external_net.id
}

resource "openstack_networking_network_v2" "network_1" {
  name = "${var.cluster_name}-network"
}

resource "openstack_networking_subnet_v2" "subnet_1" {
  name            = var.subnet_cidr
  network_id      = openstack_networking_network_v2.network_1.id
  cidr            = var.subnet_cidr
  dns_nameservers = ["188.93.16.19", "188.93.17.19"]

  # DHCP выключен: политика MKS запрещает
  # создание кластера в сети с DHCP (403 "DHCP clusters are not allowed by
  # current policy"). Karpenter-ноды получают адреса от MKS-контроллера, а не
  # от внешнего DHCP-агента Neutron.
  enable_dhcp = false
}

resource "openstack_networking_router_interface_v2" "router_interface_1" {
  router_id = openstack_networking_router_v2.router_1.id
  subnet_id = openstack_networking_subnet_v2.subnet_1.id
}

# --- Кластер MKS ---

data "selectel_mks_kube_versions_v1" "versions" {
  project_id = selectel_vpc_project_v2.project_1.id
  region     = var.region
}

resource "selectel_mks_cluster_v1" "cluster_1" {
  name       = var.cluster_name
  project_id = selectel_vpc_project_v2.project_1.id
  region     = var.region
  # ru-6 использует другой тип отказоустойчивых кластеров — MULTI_AZ
  # (HIGH_AVAILABILITY в ru-6 недоступен; в остальных пулах, наоборот, нет MULTI_AZ).
  cluster_type = var.region == "ru-6" ? "HIGH_AVAILABILITY_MULTI_AZ" : "HIGH_AVAILABILITY"
  kube_version = coalesce(
    var.kube_version,
    data.selectel_mks_kube_versions_v1.versions.default_version,
  )
  # CNI: CALICO (дефолт MKS) или CILIUM. Блок cni_cilium_settings
  # (envoy_daemonset, hubble_relay) при необходимости добавьте рядом.
  cni_type = var.cni_type

  # Karpenter: автомасштабирование и автовосстановление MKS должны быть выключены
  # (управление нодами забирает Karpenter). Без Karpenter можно вернуть true.
  enable_autorepair                 = false
  enable_patch_version_auto_upgrade = var.enable_patch_version_auto_upgrade
  network_id                        = openstack_networking_network_v2.network_1.id
  subnet_id                         = openstack_networking_subnet_v2.subnet_1.id
  maintenance_window_start          = var.maintenance_window_start
}

# --- System-нодгруппа (CPU) ---
# На ней живут: control-plane AIBrix, Envoy Gateway, контроллер Karpenter.
# GPU-ноды не описываем — их создаёт Karpenter по NodePool'ам из ../karpenter/.

# Тип загрузочного диска — из общего маппинга по сегменту
# (infra/modules/disk-type): категорию выбирает var.system_volume_category
# (basic/universal/fast), модуль подбирает доступный в зоне тип
# (в ru-6: universal → universal2, fast → fast2).
module "disk_type" {
  source   = "../modules/disk-type"
  zone     = var.availability_zone
  category = var.system_volume_category
}

resource "selectel_mks_nodegroup_v1" "system" {
  cluster_id        = selectel_mks_cluster_v1.cluster_1.id
  project_id        = selectel_vpc_project_v2.project_1.id
  region            = var.region
  availability_zone = var.availability_zone
  nodes_count       = var.system_nodes_count
  keypair_name      = var.keypair_name

  cpus        = var.system_cpus
  ram_mb      = var.system_ram_mb
  volume_gb   = var.system_volume_gb
  volume_type = module.disk_type.volume_type

  install_nvidia_device_plugin = false

  labels = {
    "nodegroup" = "system"
    "workload"  = "cpu"
  }
}

# --- Kubeconfig для корня 02-addons ---

data "selectel_mks_kubeconfig_v1" "kubeconfig" {
  cluster_id = selectel_mks_cluster_v1.cluster_1.id
  project_id = selectel_vpc_project_v2.project_1.id
  region     = var.region
}

resource "local_file" "kubeconfig" {
  content         = data.selectel_mks_kubeconfig_v1.kubeconfig.raw_config
  filename        = var.kubeconfig_output_path
  file_permission = "0600"
}
