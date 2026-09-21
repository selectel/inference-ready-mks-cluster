# SecurityPolicy (Envoy Gateway): OIDC-аутентификация n8n на edge-шлюзе.
# Применяется kubectl'ом (SecurityPolicy — CRD envoy-gateway, инвариант №2):
#   kubectl apply -f rendered/securitypolicy-n8n.yaml
#
# Зачем: n8n Community НЕ поддерживает OIDC (SAML/LDAP/OIDC — Enterprise,
# https://docs.n8n.io/administer/manage-users-and-access/verify-user-identity/use-oidc/).
# Аутентификацию выполняет сам Envoy (OIDC-флоу с dex), до бэкенда n8n
# попадают только аутентифицированные пользователи. Логин самого n8n
# (owner-аккаунт) остаётся локальным — двухслойная защита.
# Перенаправление логаута n8n /signout на /logout SecurityPolicy — в README.

apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: n8n-oidc
  namespace: n8n
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: n8n
  oidc:
    provider:
      # dex доступен снаружи; из кластера тоже резолвится публичный DNS
      issuer: https://${auth_hostname}
    clientID: n8n
    clientSecret:
      # Secret в ns n8n (key client-secret), создаёт terraform
      name: dex-n8n-client
    redirectURL: https://${n8n_hostname}/oauth2/callback
    logoutPath: /logout
    cookieNames:
      accessToken: n8n-oidc-access
      idToken: n8n-oidc-id
