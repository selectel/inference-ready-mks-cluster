# =============================================================================
# LiteLLM Proxy v1.85.1 (чарт 1.1.3, вендорен в ./chart) — auth-слой для AIBrix
# =============================================================================
# Назначение: централизованное управление API-ключами (virtual keys) перед
# LLM-шлюзом AIBrix. Цепочка:
#
#   клиент --(Bearer sk-... ключ LiteLLM)--> LiteLLM (auth, бюджеты, лимиты)
#        --> envoy/AIBrix (routing, автоскейлинг) --> vLLM
#
# БД — внешний кластер CNPG litellm-db (addons/cnpg), координация — Valkey
# (addons/valkey): prod-вариант вместо встроенных subchart'ов.
# SSO-вход в админ-UI — dex (addons/dex), generic OIDC.
# Полная документация: README.md рядом с этим файлом.
# =============================================================================

# Deployment 2 реплики на system-нодах: LB-пула больше нет (вход — только
# envoy-шлюз), так что DaemonSet не нужен; 2 реплики — отказоустойчивость.
replicaCount: 2
nodeSelector:
  nodegroup: system   # лейбл CPU-нодгруппы из infra/01-cluster/main.tf

# Внешний вход — ТОЛЬКО через Envoy Gateway (https://<litellm_hostname>),
# сервис — ClusterIP: TLS терминирует envoy, отдельный plain-HTTP
# балансировщик Octavia избыточен.
service:
  type: ClusterIP
  port: 4000

# --- БД virtual keys: кластер CNPG litellm-db (addons/cnpg) -------------------
# Секрет litellm-db-app создаёт оператор CNPG: username/password/host/port.
# Пароль нигде не задан явно (ни в values, ни в terraform).
db:
  deployStandalone: false
  useExisting: true
  endpoint: litellm-db-rw.litellm.svc.cluster.local   # дефолт, если endpointKey пуст
  database: litellm
  secret:
    name: litellm-db-app
    usernameKey: username
    passwordKey: password
    endpointKey: host   # DATABASE_HOST из секрета (сервис -rw CNPG)

# --- Координация 2 реплик (счётчики бюджетов/лимитов): Valkey (addons/valkey) --
# Без неё каждая реплика считала бы лимиты независимо.
redis:
  enabled: false   # встроенный subchart — не используем; env REDIS_* ниже

# --- Конфиг прокси ------------------------------------------------------------
proxy_config:
  model_list:
    # Клиенты зовут модель по model_name; запрос уходит в AIBrix-шлюз,
    # который сам маршрутизирует на vLLM-поды (routing/автоскейлинг AIBrix).
    # deepseek-r1-distill-llama-8b — пресет inference-charts deepseek-r1-distill-llama-8b-s3
    - model_name: deepseek-r1-distill-llama-8b
      litellm_params:
        model: openai/deepseek-r1-distill-llama-8b
        # Стабильное имя envoy/AIBrix (Service aibrix-gateway создаётся
        # terraform'ом в 02-addons, селектор по owning-gateway-лейблам):
        # хэш-имя EG-сервиса меняется между деплоями и ломало бы LiteLLM.
        api_base: http://aibrix-gateway.envoy-gateway-system.svc.cluster.local/v1
        api_key: "none"   # AIBrix/vLLM без auth (см. README, раздел о bypass)
    # qwen3-32b — пресет inference-charts qwen3-32b-s3 (GPU ≥80 ГБ)
    - model_name: qwen3-32b
      litellm_params:
        model: openai/qwen3-32b
        api_base: http://aibrix-gateway.envoy-gateway-system.svc.cluster.local/v1
        api_key: "none"
    # deepseek-finqa — LoRA через aibrix ModelAdapter (quickstart:
    # addons/models/modeladapter-finqa.yaml): маршрутизируется aibrix-шлюзом
    # по Service/EndpointSlice, который создаёт контроллер адаптера.
    - model_name: deepseek-finqa
      litellm_params:
        model: openai/deepseek-finqa
        api_base: http://aibrix-gateway.envoy-gateway-system.svc.cluster.local/v1
        api_key: "none"
    # LoRA поверх deepseek-8b: aibrix-шлюз роутит по лейблу имени модели,
    # а у LoRA-имени собственного пода нет — запрос идёт напрямую в сервис
    # пода базовой модели (vLLM сам применяет адаптер по полю model).
    - model_name: deepseek-r1-distill-llama-8b-lora
      litellm_params:
        model: openai/deepseek-r1-distill-llama-8b-lora
        api_base: http://deepseek-r1-distill-llama-8b.default.svc.cluster.local:8000/v1
        api_key: "none"
  litellm_settings:
    drop_params: true      # отсекать параметры, которых нет у vLLM
    # Метрики Prometheus (/metrics:4000) для observability-стека и дашборда
    # LiteLLM (см. addons/observability).
    callbacks:
      - prometheus
  general_settings:
    master_key: os.environ/PROXY_MASTER_KEY

# Master key берётся из Secret litellm-masterkey (создаётся terraform'ом),
# а не из значений здесь — секретов в репо нет.
masterkeySecretName: litellm-masterkey

# --- Внешние зависимости (env) -------------------------------------------------
# Valkey: REDIS_HOST/PORT/VALUE — координация реплик (fallback-механизм чарта
# при redis.enabled=false). OIDC: generic-провайдер dex (SSO админ-UI;
# бесплатно до 5 пользователей, с LiteLLM v1.76.0).
extraEnvVars:
  - name: REDIS_HOST
    value: valkey-primary.valkey.svc.cluster.local
  - name: REDIS_PORT
    value: "6379"
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: valkey-auth   # копия секрета в ns litellm (создаёт terraform)
        key: valkey-password
  # --- SSO (dex, addons/dex/README.md — раздел «LiteLLM») ---
  - name: GENERIC_CLIENT_ID
    value: litellm
  - name: GENERIC_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: dex-litellm-client   # создаёт terraform (install_dex)
        key: client-secret
  - name: GENERIC_AUTHORIZATION_ENDPOINT
    value: https://${auth_hostname}/auth
  - name: GENERIC_TOKEN_ENDPOINT
    value: https://${auth_hostname}/token
  - name: GENERIC_USERINFO_ENDPOINT
    value: https://${auth_hostname}/userinfo
  # user_id в LiteLLM = email из OIDC-клейма (дефолт preferred_username
  # у dex staticPasswords пуст) — тогда PROXY_ADMIN_ID = email админа dex,
  # роль proxy_admin выдаётся автоматически при первом SSO-входе
  - name: GENERIC_USER_ID_ATTRIBUTE
    value: email
  - name: PROXY_BASE_URL
    value: https://${litellm_hostname}
  # PROXY_ADMIN_ID — email dex-админа (создаёт terraform при install_dex:
  # Secret litellm-proxy-admin-id, см. main.tf 02-корня)
  - name: PROXY_ADMIN_ID
    valueFrom:
      secretKeyRef:
        name: litellm-proxy-admin-id
        key: proxy-admin-id

resources:
  # Старт с prisma-миграциями требует ~1.5 ГиБ — с лимитом 1 ГиБ под уходит в
  # OOMKilled (проверено). Рабочий режим легче, но запас дешевле рестартов.
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    memory: 2Gi
