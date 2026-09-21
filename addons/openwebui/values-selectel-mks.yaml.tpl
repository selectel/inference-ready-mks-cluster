# Values OpenWebUI для Selectel MKS (чарт https://helm.openwebui.com,
# репозиторий поддерживается проектом open-webui).
# Применяется terraform-корнём infra/02-addons (тумблер install_openwebui,
# требует install_litellm). HTTPRoute на edge-шлюз — addons/openwebui/manifest.yaml.

# Имя ресурсов/сервиса: иначе release "openwebui" + chart "open-webui"
# дают fullname "openwebui-open-webui"
fullnameOverride: openwebui

# Пин версии образа (инвариант №5 AGENTS.md)
image:
  tag: "v0.11.3"

# Встроенные Ollama/Pipelines не нужны: LLM-бэкенд — LiteLLM/AIBrix кластера
ollama:
  enabled: false
pipelines:
  enabled: false

# --- БД: внешний кластер CNPG openwebui-db (addons/cnpg) -----------------------
# Урл собирается из DATABASE_* env (databaseUrl пуст): компоненты — из секрета
# openwebui-db-app, который создаёт оператор CNPG (пароль нигде не задан явно).
# databaseUrl: ""

# --- WebSocket: Valkey (addons/valkey), db 2 -----------------------------------
# Встроенный redis-subchart не используется (websocket.redis.enabled=false);
# URL приходит из секрета openwebui-redis-url (создаёт terraform).
websocket:
  enabled: true
  manager: redis
  redis:
    enabled: false
  existingSecret: openwebui-redis-url
  existingSecretKey: redis-url

# --- Бэкенд OpenAI-API: LiteLLM внутри кластера --------------------------------
# ключ — копия секрета litellm/litellm-masterkey (создают terraform и helm_release litellm)
openaiBaseApiUrl: "http://litellm.litellm.svc.cluster.local:4000/v1"
openaiApiKeyExistingSecret: "litellm-masterkey"
openaiApiKeyExistingSecretKey: "masterkey"

# --- SSO: dex (addons/dex) -------------------------------------------------------
# Первый зарегистрировавшийся через OIDC пользователь получает права
# администратора (штатная логика OpenWebUI) — войти админом из blueprint
# (sso_admin_email) первым.
extraEnvVars:
  # --- БД (CNPG openwebui-db-app) ---
  - name: DATABASE_TYPE
    value: postgres
  - name: DATABASE_USER
    valueFrom:
      secretKeyRef:
        name: openwebui-db-app
        key: username
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: openwebui-db-app
        key: password
  - name: DATABASE_HOST
    valueFrom:
      secretKeyRef:
        name: openwebui-db-app
        key: host
  - name: DATABASE_PORT
    valueFrom:
      secretKeyRef:
        name: openwebui-db-app
        key: port
  - name: DATABASE_NAME
    valueFrom:
      secretKeyRef:
        name: openwebui-db-app
        key: dbname
  # --- OIDC (dex) ---
  - name: ENABLE_OAUTH_SIGNUP
    value: "true"
  - name: OAUTH_CLIENT_ID
    value: openwebui
  - name: OAUTH_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: dex-openwebui-client   # создаёт terraform (install_dex)
        key: client-secret
  - name: OPENID_PROVIDER_URL
    # Полный discovery-URL: OpenWebUI передаёт значение в server_metadata_url
    # authlib как есть (без дописывания /.well-known/...) — голый домен даёт HTML
    # и JSONDecodeError на /oauth/oidc/login (проверено)
    value: https://${auth_hostname}/.well-known/openid-configuration
  - name: OAUTH_MERGE_ACCOUNTS_BY_EMAIL
    # Админ предсоздан init-job'ом (signup с паролем): без мерджа по email
    # OIDC-вход в этот аккаунт невозможен ("email is already registered").
    # В нашем сетапе IdP один и доверенный (dex) — мердж безопасен.
    value: "true"
  - name: OAUTH_PROVIDER_NAME
    value: "Dex SSO"
  - name: OAUTH_SCOPES
    value: "openid email profile"

persistence:
  enabled: true
  # storageClass задаёт terraform (переменная storage_class_name: имя SC
  # зависит от региона, напр. fast2.ru-6)
  size: 2Gi

nodeSelector:
  nodegroup: system # GPU-ноды Karpenter — мимо

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 1Gi
