# HTTPRoute OpenWebUI на edge-шлюз (rendered/gateway-edge.yaml).
# Применяется kubectl'ом (HTTPRoute — CRD, инвариант №2):
#   export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
#   kubectl apply -f infra/02-addons/rendered/httproute-openwebui.yaml
# Сам OpenWebUI ставит terraform (install_openwebui, чарт helm.openwebui.com).
# A-запись ${chat_hostname} → LB edge-шлюза создаёт external-dns (gateway-httproute).

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openwebui
  namespace: openwebui
spec:
  parentRefs:
    - name: edge-gw
      namespace: litellm # edge-gw в ns litellm: без namespace parentRef ищется в ns маршрута
      sectionName: https # только https-listener: без sectionName цепляется и к :80, перебивая redirect
  hostnames:
    - ${chat_hostname}
  rules:
    - backendRefs:
        # Сервис чарта: fullnameOverride openwebui, порт service.port=80
        - name: openwebui
          port: 80
