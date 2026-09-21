# =============================================================================
# CNPG: кластеры PostgreSQL для litellm / n8n / openwebui
# Рендерится terraform-корнём 02-addons (install_cnpg) в rendered/cnpg-clusters.yaml.
# =============================================================================
# Формат: secret <имя>-app (создаёт оператор CNPG) содержит ключи username /
# password / dbname / host / port — их потребляют чарты сервисов через
# secretKeyRef (см. values соответствующих аддонов).
# Ноды — только system (лейбл из 01-корня); storageClass — кластерный
# fast2.<region> (передаётся переменной storage_class_name).
# =============================================================================

%{ for svc in services ~}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${svc["cluster"]}
  namespace: ${svc["namespace"]}
  labels:
    app.kubernetes.io/managed-by: terraform-render
spec:
  instances: ${instances}
  primaryUpdateStrategy: unsupervised
  # Superuser-доступ из кластера не нужен: все сервисы ходят пользователем app.
  enableSuperuserAccess: false
  bootstrap:
    initdb:
      database: ${svc["database"]}
      owner: app
%{ if backup_bucket != "" ~}
  # Бэкапы: barman-cloud → S3 (отдельный контейнер, создаёт корень 01-cluster).
  # Креды — Secret cnpg-backup-credentials в namespace кластера (создаёт
  # terraform 02-корня). Хранение 7 дней (retentionPolicy). Первый бэкап —
  # вручную: kubectl patch cluster <имя> --subresource=status --type merge \
  #   -p '{"status":{"backupRequested":true}}' (см. addons/cnpg/README.md)
  backup:
    barmanObjectStore:
      destinationPath: s3://${backup_bucket}/${svc["cluster"]}
      endpointURL: ${s3_endpoint}
      s3Credentials:
        accessKeyId:
          name: cnpg-backup-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-backup-credentials
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
        # Полный снапшот кластера ~×storage_size; 10–15 минут на 10Gi
        immediateCheckpoint: true
    retentionPolicy: 7d
%{ endif ~}
  storage:
    size: ${storage_size}
    storageClass: ${storage_class}
  # Метрики Prometheus (:9187, PodMonitor создаёт сам оператор CNPG) —
  # собирает observability-стек (Prometheus берёт все PodMonitor'ы).
  monitoring:
    enablePodMonitor: true
  postgresql:
    # Часы БД в UTC — стабильные timestamp'ы в UI прикладных сервисов
    parameters:
      timezone: UTC
  affinity:
    # БД — на system-нодах (не GPU), анти-аффинити — инстансы по разным нодам
    nodeSelector:
      nodegroup: system
    enablePodAntiAffinity: true
    podAntiAffinityType: preferred
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      memory: 1Gi
%{ endfor ~}
