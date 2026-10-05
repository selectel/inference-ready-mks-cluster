# LiteLLM Proxy — auth-слой перед AIBrix

[LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/overview) v1.85.1
(чарт litellm-helm 1.1.3, вендорен в `chart/`) — централизованное управление
API-ключами к моделям, обслуживаемым AIBrix.

```
клиенты ──(Bearer sk-… virtual key)──> https://litellm.домен
                                          │ edge-шлюз (envoy, LB, wildcard-TLS)
                                          │ auth: ключ валиден? бюджет/лимиты
                                          ▼
                                    svc/aibrix-gateway (ClusterIP, стабильное имя)
                                          │ envoy/AIBrix: routing / rate limit / KV-aware
                                          ▼
                                        vLLM (GPU-ноды Karpenter)
```

Публичный вход в кластер — ТОЛЬКО LiteLLM. Балансировщика у AIBrix нет вовсе
(сервис envoy — ClusterIP): у AIBrix нет собственной аутентификации, любой LB
был бы обходом ключей; LB + его health-чеки — лишняя точка отказа
(DEGRADED при появлении CPU-нод без envoy). LiteLLM ходит в envoy по
стабильному имени `aibrix-gateway.envoy-gateway-system.svc` (якорь-Service
создаётся terraform'ом в 02-addons; селектор — по owning-gateway-лейблам,
хэш-имя EG-сервиса меняется между деплоями и сломало бы связность).
Операторский доступ к AIBrix — `kubectl port-forward`.

## Что даёт

- **Virtual keys**: сколько угодно ключей к одной модели, у каждого — свой
  набор моделей, бюджет ($), rate limits, срок жизни; учёт spend по ключу.
- Отзыв/ротация ключей без пересоздания подов.
- OpenAI-совместимый API: у клиента меняются только `base_url` и `api_key`.

## Установка (входит в `terraform apply` инфраструктуры/02-addons, тумблер `install_litellm`)

Компоненты в namespace `litellm`:
- Deployment прокси (2 реплики, `replicaCount`) на system-нодах (лейбл
  `nodegroup=system` из `infra/01-cluster`); публичный вход — только через
  edge-шлюз (HTTPS, см. README корня «Домен и DNS»);
- Postgres (subchart, PVC на Cinder `fast2.<регион>`) — хранилище virtual keys;
- Redis (subchart) — координация реплик (счётчики бюджетов/лимитов).

Секреты не в репо: master key — в Secret `litellm/litellm-masterkey`
(генерирует terraform, `random_password`), пароль Postgres — `set_sensitive`.

## Веб-интерфейс (админка)

Откройте `https://ai.<домен>/ui` (имя выводится автоматически из `dns_zone_name`;
вход — через edge-шлюз, TLS — wildcard-сертификат) и войдите:

- **Логин**: `admin`
- **Пароль**: master key (см. блок выше — Secret `litellm/litellm-masterkey`).
  Отдельный `ui_username`/`ui_password` не настроен: админский вход UI — по
  master key (`general_settings.master_key` в values).

UI — обёртка над тем же API управления ключами: создание/отзыв virtual keys,
бюджеты, лимиты, spend по ключам. Всё, что можно в UI, можно и curl'ом из
раздела ниже. **Master key — не для клиентов**: полный админ-доступ, клиентам
выдавайте только virtual keys.

(Проверено на v1.85.1: форма входа отправляет POST на `/login`; путь
`/user/auth/login` из старых версий не отвечает — 404.)

## Управление ключами

Master key (админ-доступ к API управления):

```bash
export KUBECONFIG=$(cd infra/01-cluster && terraform output -raw kubeconfig_path)
MASTER=$(kubectl -n litellm get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d)
```

Базовый URL: `https://ai.<домен>` (edge-шлюз — основной путь, см. README
корня «Домен и DNS»). Без домена / для отладки — локальный туннель к сервису
(ClusterIP, порт 4000; отдельного публичного IP у LiteLLM больше нет):

```bash
kubectl -n litellm port-forward svc/litellm 4000:4000   # затем base_url http://127.0.0.1:4000
```

Создать ключ пользователю (полный синтаксис — docs.litellm.ai, «Virtual Keys»):

```bash
curl -X POST https://$LITELLM_HOSTNAME/key/generate -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"vasya","models":["deepseek-r1-distill-llama-8b"],"max_budget":5,"duration":null}'
# sk-... показывается ОДИН раз — сохранить/передать пользователю сразу.
```

Список / инфо (в листинге — только хэши, не сами ключи):

```bash
curl https://$LITELLM_HOSTNAME/key/list -H "Authorization: Bearer $MASTER"
curl "https://$LITELLM_HOSTNAME/key/info?key=<hash>" -H "Authorization: Bearer $MASTER"
```

Отозвать: `curl -X POST https://$LITELLM_HOSTNAME/key/delete -H "Authorization: Bearer $MASTER" -d '{"keys":["<hash>"]}' ...`.

Использование клиентом:

```bash
curl https://$LITELLM_HOSTNAME/v1/chat/completions -H "Authorization: Bearer sk-..." \
  -d '{"model":"deepseek-r1-distill-llama-8b","messages":[...]}'
```

## Известные ограничения / решения

- **Единый публичный вход**: у AIBrix нет LB вообще (ClusterIP), обойти
  auth-слой нельзя; операторский доступ к AIBrix — `kubectl port-forward`
  (см. `addons/aibrix/docs/02` §3).
- **Память**: старт прокси с prisma-миграциями занимает ~1.5 ГиБ — в values
  стоит limit 2Gi (с 1Gi ловили OOMKilled, проверено).
- **anti-affinity нельзя**: чарт наследует `affinity`/`nodeSelector` в
  migrations-job (helm pre-install хук) — required podAntiAffinity
  гарантированно вешает его в Pending.
- **Кастомные заголовки AIBrix** (`routing-strategy`, `target-pod`) не
  пробрасываются LiteLLM автоматически — работают дефолтные стратегии роутинга.
  Для специфичных стратегий задавайте заголовки на уровне модели
  (`litellm_params.extra_headers` — не проверено) или через операторский
  доступ к AIBrix напрямую.
- HA-вариант (внешний Postgres + Redis Sentinel) — если ключей/нагрузки станет
  много; сейчас одиночный Postgres в кластере достаточен для key-store.

## Обновление vendored чарта

```bash
git clone --depth 1 https://github.com/BerriAI/litellm.git /tmp/litellm
rm -rf addons/litellm/chart && cp -r /tmp/litellm/helm/litellm-helm addons/litellm/chart
```
Затем вручную: сравнить локальные шаблоны с новыми upstream (локальных
патчей чарта НЕТ), обновить версии в этом README и
`Chart.yaml`-примечание в `infra/02-addons/main.tf` (в комментариях),
прогнать проверки из AGENTS.md.
Чарт публикует OCI-копию в `ghcr.io/berriai/litellm-helm`, но там задержка;
вендоринг из main-ветки — основной путь (как у AIBrix).

## Добавление новой модели

В `addons/litellm/values-selectel-mks.yaml.tpl` → `proxy_config.model_list`
добавить блок с `model_name` = имени модели в AIBrix и `api_base`
`http://aibrix-gateway.envoy-gateway-system.svc.cluster.local/v1`.
Затем `terraform apply` (02-addons).
