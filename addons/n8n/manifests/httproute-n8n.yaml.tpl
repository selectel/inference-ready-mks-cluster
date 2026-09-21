# HTTPRoute n8n на edge-шлюз (rendered/gateway-edge.yaml).
# Применяется kubectl'ом (HTTPRoute — CRD, инвариант №2):
#   export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
#   kubectl apply -f infra/02-addons/rendered/httproute-n8n.yaml
# Сам n8n ставит terraform (install_n8n, чарт community-charts.github.io).
# A-запись ${n8n_hostname} → LB edge-шлюза создаёт external-dns (gateway-httproute).

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: n8n
  namespace: n8n
spec:
  parentRefs:
    - name: edge-gw
      namespace: litellm # edge-gw в ns litellm: без namespace parentRef ищется в ns маршрута
      sectionName: https # только https-listener: без sectionName цепляется и к :80, перебивая redirect
  hostnames:
    - ${n8n_hostname}
  rules:
    - backendRefs:
        # Сервис чарта: fullname n8n, порт service.port=5678
        - name: n8n
          port: 5678
