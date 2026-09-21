# Публичный HTTPS-вход кластера (edge) через Envoy Gateway (Gateway API).
# Один LB + один wildcard-сертификат *.${dns_zone_name} на ВСЕ сервисы:
# добавление сервиса = новый HTTPRoute к этому Gateway (пример —
# httproute-example.yaml рядом; litellm — httproute-litellm.yaml.tpl).
#
# Паттерн из webinar Selectel (github.com/selectel/webinar-llm-on-mks,
# apps/03.cert-manager-external-dns): TLS терминируется на envoy секретом
# из Certificate (rendered/certificate-wildcard.yaml), A-записи имён сервисов
# создаёт external-dns (source gateway-httproute) по HTTPRoute'ам.
#
# РЕНДЕРИТСЯ terraform'ом (переменная dns_zone_name) и применяется kubectl'ом
# (Gateway API — CRD-ресурсы, инвариант №2):
#   kubectl apply -f rendered/gateway-edge.yaml

apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: edge-proxy-config
  namespace: litellm
spec:
  provider:
    type: Kubernetes
    kubernetes:
      # Deployment (не DaemonSet): externalTrafficPolicy Cluster — членом пула
      # может быть любая нода, под envoy на каждой не нужен.
      envoyDeployment:
        pod:
          nodeSelector:
            nodegroup: system # GPU-ноды Karpenter — мимо
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Cluster
        annotations:
          # Пул Octavia — только system-ноды (иначе GPU-ноды без envoy роняют LB в DEGRADED)
          loadbalancer.openstack.org/node-selector: nodegroup=system
          # Дефолт Octavia (50 с) обрывает долгие LLM-генерации — час, значения в мс
          loadbalancer.openstack.org/timeout-client-data: "3600000"
          loadbalancer.openstack.org/timeout-member-data: "3600000"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: edge-eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: edge-proxy-config
    namespace: litellm
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge-gw
  namespace: litellm
spec:
  gatewayClassName: edge-eg
  listeners:
    - name: https
      # wildcard-listener: принимает любой *.${dns_zone_name}
      hostname: "*.${dns_zone_name}"
      port: 443
      protocol: HTTPS
      allowedRoutes:
        # маршруты из ЛЮБОГО namespace — так новые сервисы цепляются
        # своим HTTPRoute'ом, не трогая сам Gateway
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          # Secret из rendered/certificate-wildcard.yaml
          - name: wildcard-tls
            kind: Secret
    - name: http-redirect
      # без hostname: ловим ВСЕ соединения на :80 (любой Host, вкл. прямой IP) и
      # ниже HTTPRoute отдаёт 301 на https того же хоста
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: edge-http-redirect
  namespace: litellm
spec:
  # http:// → 301 https:// ДЛЯ ВСЕХ соединений на :80: без hostnames
  # маршрут совпадает с любым Host (вкл. обращение по IP балансировщика),
  # RequestRedirect без hostname сохраняет исходный хост
  parentRefs:
    - name: edge-gw
      sectionName: http-redirect
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            port: 443
            statusCode: 301
