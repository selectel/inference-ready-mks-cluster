output "gateway_lb_ip_command" {
  description = "Публичный IP edge-шлюза (LB envoy — единственный публичный вход кластера)."
  value       = "kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=edge-gw -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'"
}

output "quickstart_test_command" {
  description = "smoke-тест шлюза через HTTPS-вход edge-шлюза (если install_litellm = true)."
  value       = (var.install_litellm && var.install_external_dns && var.install_cert_manager && var.dns_zone_name != "") ? format("curl https://%s/health/liveliness", local.litellm_hostname) : "curl http://<LB_IP>:4000/health/liveliness (HTTPS-вход ai.<домен> требует external-dns + cert-manager + dns_zone_name)"
}

output "cert_apply_command" {
  description = "Применить отрендеренные CRD-манифесты (ClusterIssuer, wildcard-Certificate, edge-Gateway, HTTPRoute litellm). Запускать из каталога infra/02-addons ПОСЛЕ terraform apply."
  value = join(" && ", compact([
    var.install_cert_manager ? "kubectl apply -f rendered/clusterissuer-letsencrypt.yaml" : "",
    (var.install_cert_manager && var.dns_zone_name != "") ? "kubectl apply -f rendered/certificate-wildcard.yaml" : "",
    (var.install_envoy_gateway && var.dns_zone_name != "") ? "kubectl apply -f rendered/gateway-edge.yaml" : "",
    (var.install_litellm && var.install_external_dns && var.install_cert_manager && var.dns_zone_name != "") ? "kubectl apply -f rendered/httproute-litellm.yaml" : "",
  ]))
}

output "dns_test_command" {
  description = "Проверка A-записи и сертификата (после apply + cert_apply_command): IP — LB edge-шлюза (envoy, HTTPS)."
  value       = (var.install_litellm && var.install_external_dns && var.install_cert_manager && var.dns_zone_name != "") ? format("dig +short %s && kubectl -n litellm get certificate wildcard && kubectl -n litellm get gateway edge-gw", local.litellm_hostname) : ""
}
