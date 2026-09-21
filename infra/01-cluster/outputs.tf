output "cluster_id" {
  description = "ID кластера MKS — нужен для установки Karpenter (controller.settings.clusterID) в 02-addons."
  value       = selectel_mks_cluster_v1.cluster_1.id
}

output "project_id" {
  value = selectel_vpc_project_v2.project_1.id
}

output "region" {
  value = var.region
}

output "kubeconfig_path" {
  description = "Путь к kubeconfig. Используйте: export KUBECONFIG=$(terraform output -raw kubeconfig_path)."
  value       = abspath(local_file.kubeconfig.filename)
}

# --- Для корня 02-addons: cert-manager / external-dns с Selectel DNS ---
# (02-addons читает их через terraform_remote_state при create_zone_and_user=true)

output "account_id" {
  description = "ID учётной записи Selectel (= sel_domain_name; нужен вебхукам cert-manager/external-dns для keystone-аутентификации)."
  value       = var.sel_domain_name
}

output "dns_user_name" {
  description = "Имя сервисного пользователя DNS. Пусто, если DNS-секция неактивна."
  value       = length(selectel_iam_serviceuser_v1.dns_user) == 0 ? "" : selectel_iam_serviceuser_v1.dns_user[0].name
}

output "dns_user_password" {
  description = "Пароль сервисного пользователя DNS (для 02-addons). Пусто, если DNS-секция неактивна."
  value       = length(random_password.dns_user) == 0 ? "" : random_password.dns_user[0].result
  sensitive   = true
}
