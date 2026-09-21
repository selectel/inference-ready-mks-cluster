# HTTPRoute dex на edge-шлюз (rendered/gateway-edge.yaml).
# Применяется kubectl'ом (HTTPRoute — CRD, инвариант №2):
#   export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
#   kubectl apply -f rendered/httproute-dex.yaml
# A-запись auth-имени (переменная auth_hostname) → LB edge-шлюза создаёт
# external-dns.
# Чарт dexidp/dex ставит terraform (install_dex); TLS терминирует edge-шлюз
# wildcard-сертификатом.

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: dex
  namespace: dex
spec:
  parentRefs:
    - name: edge-gw
      namespace: litellm # edge-gw в ns litellm (см. gateway-edge.yaml.tpl)
      sectionName: https
  hostnames:
    - ${auth_hostname}
  rules:
    - backendRefs:
        # Сервис чарта dex: fullname dex, http-порт 5556 (values service.ports.http)
        - name: dex
          port: 5556
