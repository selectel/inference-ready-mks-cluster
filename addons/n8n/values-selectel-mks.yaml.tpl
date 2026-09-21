# Values n8n для Selectel MKS (community-чарт github.com/community-charts,
# официальный чарт n8n не выпускается).
# Применяется terraform-корнём infra/02-addons (тумблер install_n8n).
# HTTPRoute на edge-шлюз — addons/n8n/manifest.yaml; OIDC-аутентификация —
# Envoy SecurityPolicy (n8n Community не поддерживает OIDC, см. addons/dex/README.md).

# Пин версии образа (инвариант №5 AGENTS.md)
image:
  tag: "2.38.4"

# RWO-PVC + RollingUpdate = дедлок рестарта (новый под ждёт том, занятый
# старым): Recreate, как у vLLM-деплоев (см. addons/models/README.md).
strategy:
  type: Recreate

# Метрики Prometheus (/metrics, env N8N_METRICS=true рендерит сам чарт) и
# ServiceMonitor (селектор любой — прометей observability берёт все:
# serviceMonitorSelectorNilUsesHelmValues: false).
serviceMonitor:
  enabled: true
  include:
    apiEndpoints: true

# БД — внешний кластер CNPG n8n-db (addons/cnpg): prod-вариант queue-режима
# (sqlite не поддерживает worker'ы). Секрет n8n-db-app создаёт оператор CNPG,
# пароль нигде не задан явно.
db:
  type: postgresdb

externalPostgresql:
  host: n8n-db-rw.n8n.svc.cluster.local
  port: 5432
  database: n8n
  username: app   # стандартный пользователь CNPG (bootstrap.owner)
  existingSecret: n8n-db-app
  existingSecretPasswordKey: password

# Queue-режим (prod): main (UI) + worker (исполнение) + webhook (приём) —
# масштабируются независимо; общий encryption-key чарт кладёт в Secret сам.
worker:
  mode: queue
  count: 1

webhook:
  mode: queue
  # базовый URL вебхуков: публичный вход через edge-шлюз
  url: "https://${n8n_hostname}/"

# Очередь Bull — Valkey (addons/valkey), db 1
externalRedis:
  host: valkey-primary.valkey.svc.cluster.local
  port: 6379
  database: 1
  existingSecret: valkey-auth   # копия секрета в ns n8n (создаёт terraform)
  existingPasswordKey: valkey-password

main:
  # корректные ссылки/редиректы редактора за reverse-proxy
  editorBaseUrl: "https://${n8n_hostname}"
  persistence:
    enabled: true
    # storageClass задаёт terraform (переменная storage_class_name: имя SC
    # зависит от региона, напр. fast2.ru-6)
    size: 2Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      # 512Mi не хватает на старт n8n 2.x (heap при инициализации ~250 МБ+)
      memory: 1Gi

nodeSelector:
  nodegroup: system # GPU-ноды Karpenter — мимо
