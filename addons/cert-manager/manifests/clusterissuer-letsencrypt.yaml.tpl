# ClusterIssuer: Let's Encrypt через DNS-хостинг Selectel.
# РЕНДЕРИТСЯ terraform'ом (02-addons: local_file + этот шаблон) — email
# приходит из переменной letsencrypt_email (tfvars blueprint'а).
# КРЕДЫ менять не нужно — Secret selectel-dns-credentials создаёт terraform
# (kubernetes_secret_v1.cert_manager_dns_credentials).
#
# Применяется kubectl'ом (ClusterIssuer — CRD-ресурс, инвариант №2):
#   kubectl apply -f rendered/clusterissuer-letsencrypt.yaml
# Для отладки переключитесь на staging-сервер
# (https://acme-staging-v02.api.letsencrypt.org/directory) — без rate limit.

apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-selectel-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-selectel-account-key
    solvers:
      - dns01:
          webhook:
            groupName: acme.selectel.ru # дефолт чарта cert-manager-webhook-selectel
            solverName: selectel
            config:
              dnsSecretRef:
                name: selectel-dns-credentials # Secret в ns cert-manager
              # Опционально (значения по умолчанию, секунды):
              # ttl: 120    # default 60
              # timeout: 60 # default 40
