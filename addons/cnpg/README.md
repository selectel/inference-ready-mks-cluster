# CNPG — PostgreSQL для litellm / n8n / openwebui

[CloudNativePG](https://cloudnative-pg.io): оператор PostgreSQL + по одному
кластеру БД на прикладной сервис (замена встроенным bitnami-subchart'ам и
sqlite — пользовательская причина: «prod-инсталляции» отдельных БД).

## Состав

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| Оператор cloudnative-pg (чарт) | 0.29.0 (CNPG 1.30.0) | remote-репо `cloudnative-pg.github.io/charts`, ставит terraform |
| Кластеры `Cluster` (CR) | — | **kubectl**: рендерит terraform в `rendered/cnpg-clusters.yaml` |

Кластеры (по одному на сервис, в ns самого сервиса):

| Кластер | Namespace | База | Потребитель |
|---------|-----------|------|-------------|
| `litellm-db` | litellm | litellm | LiteLLM (db.useExisting) |
| `n8n-db` | n8n | n8n | n8n (externalPostgresql) |
| `openwebui-db` | openwebui | openwebui | OpenWebUI (DATABASE_* env) |

Почему Cluster-ресурсы через kubectl, а не terraform — инвариант №2 AGENTS.md:
CRD `postgresql.cnpg.io/v1` не зарегистрирован на этапе первого plan.
Аналогично ClusterIssuer (cert-manager) — terraform рендерит, kubectl применяет.

## Секреты

Оператор создаёт секрет `<cluster>-app` (пользователь `app`, БД из
bootstrap) с ключами `username`, `password`, `dbname`, `host`, `port`, `uri`.
Чарты сервисов подключают их через secretKeyRef — пароли БД нигде не
задаются явно (в т.ч. в terraform), ротация — через оператор.

## Установка / обновление

```bash
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
cd infra/02-addons && terraform apply        # оператор (helm) + рендер манифестов
kubectl apply -f rendered/cnpg-clusters.yaml # кластеры БД (CRD-ресурсы)
kubectl -n litellm get cluster               # статус: фаза Cluster in healthy state
```

Порядок при переустановке сервисов: сначала кластеры БД (kubectl), затем
`terraform apply` 02-корня с новыми values (иначе поды сервисов стартуют
без БД — перезапустятся после готовности кластера).

## Параметры (blueprint.tfvars)

- `install_cnpg` — тумблер (оператор + рендер кластеров);
- `cnpg_instances` — инстансов на кластер (дефолт 2: primary + реплика);
- `cnpg_storage_size` — размер PV (дефолт 10Gi);
- `storage_class_name` — общий для кластера SC (fast2.<region>).

## Бэкапы (barman-cloud → S3)

При `create_object_storage=true` (корень 01-cluster) кластеры получают
секцию backup: wal + снапшоты barman-cloud'ом в отдельный S3-контейнер
(`backup_bucket_name`, дефолт inference-cnpg-backups), retention 7 дней.
Креды — Secret cnpg-backup-credentials в каждом ns (создаёт terraform).

Первый/очередной бэкап — вручную (по требованию, Backup CR):

```bash
kubectl -n litellm apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: litellm-db-manual
spec:
  cluster:
    name: litellm-db
EOF
kubectl get backups -A   # статус: phase completed
```

(Проверено 2026-09-11: все три кластера — completed; barman работает с
Selectel S3 path-style из коробки.)

Расписание (schedule) не включено (осознанно): wal-архив пишется
непрерывно, полный снапшот — по требованию; для расписания добавьте
`spec.backup.schedule` в clusters.yaml.tpl.

## Грабли

- **CRD применяется один раз**: при upgrade оператора helm не обновляет CRD
  (как и у AIBrix) — при смене мажорной версии CNPG обновить
  `kubectl apply -f` CRD из чарта вручную.
- System-нодгруппа из 2 нод и 6 postgres-подов: анти-аффинити `preferred`
  (не required) — при нехватке нод инстансы лягут на одну ноду, а не зависнут
  в Pending.
