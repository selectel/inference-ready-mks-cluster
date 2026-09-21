# =============================================================================
# Конфигурация dex (https://dexidp.io/docs/): terraform рендерит этот шаблон
# и кладёт в Secret dex-config (ns dex) — чарт читает config из этого секрета
# (configSecret.create=false, configSecret.name=dex-config).
# Секретные поля (bcrypt-хэш админа, client-секреты) интерполируются
# terraform'ом из random_password — в репо их нет.
# =============================================================================

# Issuer — публичный адрес dex за edge-шлюзом (TLS от wildcard-сертификата).
issuer: ${issuer}

web:
  http: 0.0.0.0:5556
  allowedOrigins:
    - ${issuer}

# Хранилище: staticClients + staticPasswords целиком статичны, живое состояние
# OIDC-флоу короткоживущее — одной реплики с in-memory storage достаточно.
# ponytail: при >1 реплики dex или динамических клиентах — storage: kubernetes.
storage:
  type: memory

# --- Локальный админ (SSO-вход в панели) ---
enablePasswordDB: true
staticPasswords:
  - email: ${admin_email}
    hash: ${admin_bcrypt}
    username: admin
    userID: ${admin_user_id}

# --- Клиенты панелей ---
staticClients:
  - id: openwebui
    name: OpenWebUI
    secret: ${openwebui_client_secret}
    redirectURIs:
      - https://${chat_hostname}/oauth/oidc/callback
  - id: litellm
    name: LiteLLM Admin UI
    secret: ${litellm_client_secret}
    redirectURIs:
      - https://${litellm_hostname}/sso/callback
  # Клиент n8n потребляет не сам n8n (OIDC там Enterprise), а Envoy Gateway
  # (SecurityPolicy с OIDC-провайдером перед HTTPRoute n8n — см. README).
  - id: n8n
    name: n8n (через Envoy SecurityPolicy)
    secret: ${n8n_client_secret}
    redirectURIs:
      - https://${n8n_hostname}/oauth2/callback
%{ if grafana_client_secret != "" ~}
  # Grafana (observability-стек): вход SSO, роль Viewer
  - id: grafana
    name: Grafana (observability)
    secret: ${grafana_client_secret}
    redirectURIs:
      - https://${grafana_hostname}/login/generic_oauth
%{ endif ~}
%{ if osd_client_secret != "" ~}
  # OpenSearch Dashboards (observability): OIDC через security-плагин
  - id: opensearch-dashboards
    name: OpenSearch Dashboards
    secret: ${osd_client_secret}
    redirectURIs:
      - https://${osd_hostname}/auth/openid/login
%{ endif ~}

# Парольная БД — единственный «коннектор»; внешние IdP не подключены.
connectors: []
oauth2:
  skipApprovalScreen: true
