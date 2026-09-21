# HTTPRoute LiteLLM на edge-шлюзе (rendered/gateway-edge.yaml).
# РЕНДЕРИТСЯ terraform'ом (local litellm_hostname = ai.<dns_zone_name>) и применяется kubectl'ом:
#   kubectl apply -f rendered/httproute-litellm.yaml
# A-запись ai.<домен> → LB edge-шлюза создаёт external-dns (gateway-httproute).

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: litellm
  namespace: litellm
spec:
  parentRefs:
    - name: edge-gw
      sectionName: https # только https-listener: без sectionName цепляется и к :80, перебивая redirect
  hostnames:
    - ${litellm_hostname}
  rules:
    - backendRefs:
        # Сервис LiteLLM (ClusterIP, внутренний порт 4000): единственный
        # публичный вход — этот HTTPS-маршрут через envoy
        - name: litellm
          port: 4000
