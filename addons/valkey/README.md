# Valkey (Redis-совместимый) — общий кэш/очередь для litellm / n8n / openwebui

Заменяет встроенные redis-subchart'ы одной инсталляцией (пользовательская
причина: единый redis/valkey на прикладные сервисы). Valkey — открытый форк
Redis 7.2 (лицензия BSD, после смены лицензии Redis на RSALv2/SSPL).

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| Чарт valkey (bitnami) | 6.2.19 | remote-репо `charts.bitnami.com/bitnami`, ставит terraform |
| Образ valkey | 8.1.3 (`docker-registry.selectel.ru/bitnamilegacy/valkey`) | пин: свежих versioned-тегов у bitnami нет (Broadcom), у bitnamilegacy — есть; чарт совместим. Через зеркало Selectel: registry-1.docker.io из сети кластера недоступен |

## Потребители (логические БД)

| Потребитель | db | Назначение |
|-------------|----|-----------|
| LiteLLM | 0 (дефолт env REDIS_*) | координация реплик (budget/rpm-счётчики) |
| n8n | 1 | Bull-queue (queue-режим worker/webhook) |
| OpenWebUI | 2 | websocket-менеджер (redis-url) |

Разделение по db-индексам вместо отдельных инстансов — очередь n8n и
websocket-события маленькие; нагрузки уровня «нужен отдельный инстанс» нет.
Инстанс один (не HA): это кэш/очередь с AOF-персистентностью, деградация
при рестарте — пауза на десятки секунд, не потеря данных сервисов.

## Пароль

Генерируется terraform (`random_password`), кладётся в Secret `valkey-auth`
(key `valkey-password`) в ns valkey и копиями в ns litellm / n8n / openwebui
(secretKeyRef не умеет чужие namespace — тот же паттерн, что у
litellm-masterkey). Ротация: сменить random_password (taint) и перекатить
поды сервисов.

## Установка

```bash
cd infra/02-addons && terraform apply   # install_valkey = true
```
