# HTTPRoute grafana (observability) на edge-шлюз (rendered/gateway-edge.yaml).
# Применяется kubectl'ом (HTTPRoute — CRD, инвариант №2):
#   export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
#   kubectl apply -f infra/02-addons/rendered/httproute-grafana.yaml
# A-запись grafana.<домен> → LB edge-шлюза создаёт external-dns
# (gateway-httproute). Стек ставит terraform (install_observability).

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: edge-gw
      namespace: litellm # edge-gw в ns litellm (см. gateway-edge.yaml.tpl)
      sectionName: https
  hostnames:
    - ${grafana_hostname}
  rules:
    - backendRefs:
        # Сервис kube-prometheus-stack (fullnameOverride из чарта), порт 80
        - name: kube-prometheus-stack-grafana
          port: 80
