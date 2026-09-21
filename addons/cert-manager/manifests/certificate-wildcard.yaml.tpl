# Wildcard-сертификат *.${dns_zone_name} — один на все сервисы кластера.
# РЕНДЕРИТСЯ terraform'ом (переменная dns_zone_name из blueprint.tfvars):
# cert-manager выпускает через DNS-01 (Selectel DNS-хостинг).
#
# Применяется kubectl'ом (Certificate — CRD-ресурс, инвариант №2):
#   kubectl apply -f rendered/certificate-wildcard.yaml
#
# Секрет wildcard-tls появится в ns litellm (там же, где Gateway edge-gw),
# терминирует TLS все имена *.${dns_zone_name}.

apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard
  namespace: litellm
spec:
  secretName: wildcard-tls
  dnsNames:
    - "*.${dns_zone_name}"
  issuerRef:
    name: letsencrypt-selectel-dns01
    kind: ClusterIssuer
