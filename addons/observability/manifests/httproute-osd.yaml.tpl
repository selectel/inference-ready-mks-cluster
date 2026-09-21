# HTTPRoute OpenSearch Dashboards (observability) на edge-шлюз
# (rendered/gateway-edge.yaml). Применяется kubectl'ом (HTTPRoute — CRD,
# инвариант №2):
#   export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
#   kubectl apply -f infra/02-addons/rendered/httproute-osd.yaml
# A-запись osd.<домен> → LB edge-шлюза создаёт external-dns
# (gateway-httproute). Сервис дашбордов создаёт оператор OpenSearch.

apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: opensearch-dashboards
  namespace: monitoring
spec:
  parentRefs:
    - name: edge-gw
      namespace: litellm # edge-gw в ns litellm (см. gateway-edge.yaml.tpl)
      sectionName: https
  hostnames:
    - ${osd_hostname}
  rules:
    - backendRefs:
        # Сервис дашбордов, порт 5601 (web-UI)
        - name: opensearch-dashboards
          port: 5601
