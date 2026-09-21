# cert-manager + Selectel DNS01-webhook

[cert-manager](https://cert-manager.io) v1.21.1 (чарт `v1.21.1`, ставится из
`charts.jetstack.io`) + [Selectel DNS01-webhook](https://github.com/selectel/cert-manager-webhook-selectel)
(чарт `1.4.0` из helm-репо `selectel.github.io/cert-manager-webhook-selectel`) —
TLS-сертификаты Let's Encrypt с подтверждением домена через DNS-хостинг Selectel.

Устанавливается terraform-корнем `infra/02-addons` (тумблер `install_cert_manager`).
Требует домен в DNS-хостинге Selectel: либо создаваемый terraform'ом 01-корня
(`create_zone_and_user = true`, дефолт), либо уже существующий в любом аккаунте
(`false` + dns-переменные) — см. «Домен и DNS» в README корня.

## Что где лежит

| Что | Где |
|---|---|
| cert-manager (чарт) | `helm_release.cert_manager` в `infra/02-addons/main.tf` |
| Selectel-webhook (чарт) | `helm_release.cert_manager_webhook` там же |
| Креды DNS-пользователя | Secret `cert-manager/selectel-dns-credentials` (создаёт terraform: `username`, `password`, `account_id`, `project_id`) |
| ClusterIssuer (шаблон) | `manifests/clusterissuer-letsencrypt.yaml.tpl` — terraform рендерит его в `infra/02-addons/rendered/`, email — из переменной `letsencrypt_email` |
| Wildcard-сертификат `*.домен` | `manifests/certificate-wildcard.yaml.tpl` — рендер по `dns_zone_name`, Secret `wildcard-tls` |
| Поды | только на нодах `nodegroup=system` (GPU-ноды дороги) |

## Использование

1. Домен делегирован в Selectel (зона в DNS-хостинге — см. README корня).
2. Установите аддон: `install_cert_manager = true` + dns-переменные и
   `letsencrypt_email` в tfvars → `terraform apply` (02-addons).
3. Примените отрендеренные CRD-манифесты (после apply; команда также в output
   `cert_apply_command`):

```bash
export KUBECONFIG=$(cd infra/01-cluster && terraform output -raw kubeconfig_path)
cd infra/02-addons
kubectl apply -f rendered/clusterissuer-letsencrypt.yaml
kubectl apply -f rendered/certificate-wildcard.yaml   # если задан dns_zone_name
```

4. Проверка:

```bash
kubectl get clusterissuer letsencrypt-selectel-dns01   # READY True
kubectl -n litellm get certificate wildcard             # READY True, Secret wildcard-tls
```

Секрет `wildcard-tls` (cert+key на все имена `*.домен`) появится в ns `litellm` —
им терминирует TLS edge-шлюз (`manifests/gateway-edge.yaml.tpl`, см. README
корня «Домен и DNS»). A-записи имён сервисов создаёт external-dns
(`addons/external-dns-selectel/README.md`) по их HTTPRoute'ам.

**Сертификат выпустится только после делегации домена** на NS Selectel
(`a.ns.selectel.ru … d.ns.selectel.ru` у регистратора): DNS-01 челлендж
Let's Encrypt проверяется через публичный DNS. До делегации Certificate
останется в `READY False` — это ожидаемо.

Навесить TLS-терминацию на сам LB Octavia — отдельный шаг
(`service.beta.openstack.org/default-tls-container-ref`, Barbican) — **не проверено**.

## Известные допущения

- Совместимость Selectel-webhook 1.4.0 с cert-manager 1.21.x — по API
  DNS01-solver webhook'ов не менялась, но связка живьём не проверялась.
- Обновление версий чартов — переменными `cert_manager_chart_version`
  / `cert_manager_webhook_chart_version` (осознанно, см. AGENTS.md).
- Образы тянутся из `quay.io/jetstack` и `ghcr.io`; при необходимости
  зеркалируйте в docker-registry.selectel.ru (как vLLM, см. README корня).
