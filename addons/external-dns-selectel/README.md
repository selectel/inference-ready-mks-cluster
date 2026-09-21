# external-dns + Selectel-webhook

[external-dns](https://github.com/kubernetes-sigs/external-dns) v0.22.0 +
[Selectel DNS-webhook](https://github.com/selectel/external-dns-selectel-webhook)
v0.2.0 (sidecar). У чарта Selectel нет — поэтому тут свой мини-чарт
(`chart/` этого каталога), ставит terraform-корень `infra/02-addons`
тумблером `install_external_dns`.

Синхронизирует DNS-записи в зоне `dns_zone_name` (DNS-хостинг Selectel):
Service типа LoadBalancer и Ingress с annotation hostname получают
A-запись автоматически. Зона и сервисный пользователь: либо создаются terraform'ом
01-корня (`create_zone_and_user = true`, дефолт), либо уже существуют в любом
аккаунте (`false` + dns-переменные) — см. «Домен и DNS» в README корня.

## Что где лежит

| Что | Где |
|---|---|
| Чарт (свой) | `helm_release.external_dns` в `infra/02-addons/main.tf`, путь `../../addons/external-dns-selectel` |
| Креды | Пароль — в Secret `external-dns/<release>-selectel` (values `selectel.password`, подаётся terraform'ом через `set_sensitive` — виден только в state) |
| Поды | только на нодах `nodegroup=system` |
| Политика | `upsert-only` по умолчанию: записи создаются/обновляются, но не удаляются. `sync` (удаление пропавших) — в values чарта |

## Использование

Публичный вход кластера — LB edge-шлюза. DNS-имя LiteLLM выводится
автоматически: `ai.<dns_zone_name>` (local в 02-корне, как n8n/openwebui) —
external-dns создаст A-запись по IP балансировщика (gateway-httproute),
сертификат — cert-manager (`addons/cert-manager/`).

Для Service/Ingress работает стандартная аннотация
`external-dns.alpha.kubernetes.io/hostname` (или `spec.rules[].host`).
Источники зафиксированы в шаблоне чарта: `--source=service`,
`--source=ingress`, `--source=gateway-httproute` — основной путь этого
репо (A-записи ai/chat/n8n/auth.<домен> создаются по HTTPRoute'ам
edge-шлюза, проверено).

## Известные допущения

- external-dns v0.14.2 — связка, проверенная Selectel
  (webinar-llm-on-mks/apps/03); v0.22 падал на informer-таймауте EndpointSlice.
- Совместимость webhook v0.2.0 с external-dns v0.14.2 — по webhook-API стабильна.
- **Одна реплика, strategy Recreate** — единственный владелец записей.
- Обновление версий образов — в `values.yaml` чарта (пиннуты, см. AGENTS.md).
- Образ webhook из `ghcr.io` — при необходимости зеркалируйте
  в docker-registry.selectel.ru (как vLLM, см. README корня).
