# Dex — единая SSO-авторизация (OIDC) для веб-панелей

[Dex](https://dexidp.io) — OIDC-провайдер (CNCF): единый вход во все панели
кластера. Выбран вместо Keycloak: конфигурация декларативная (рендерится из
blueprint), не нужна своя БД, нет UI-слоя. Для команды с ротацией паролей и
саморегистрацией пользователей Keycloak уместнее (но тяжелее).

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| Чарт dex (dexidp) | 0.24.1 | remote-репо `charts.dexidp.io`, ставит terraform |
| dex | v2.44.0 (appVersion чарта) | образ `ghcr.io/dexidp/dex` |

## Матрица OIDC-поддержки панелей (проверено по докам)

| Панель | Нативный OIDC | Как подключено |
|--------|---------------|----------------|
| OpenWebUI | да (`OAUTH_CLIENT_ID/SECRET`, `OPENID_PROVIDER_URL`) | env чарта |
| LiteLLM | да, с v1.76.0 бесплатно до 5 пользователей (generic OIDC: `GENERIC_*` env) | env чарта |
| n8n (Community) | **нет** — OIDC/SAML/LDAP только Enterprise | Envoy Gateway SecurityPolicy (authn на edge-шлюзе) |

Админ-пользователь (локальная парольная БД dex, `enablePasswordDB`):
email — переменная `sso_admin_email` (blueprint), пароль генерирует
terraform и кладёт в Secret `dex-admin` (key `password`):

```bash
kubectl -n dex get secret dex-admin -o jsonpath='{.data.password}' | base64 -d
```

Первый вход админом: OpenWebUI — первый зарегистрировавшийся пользователь
получает права администратора (штатная логика); LiteLLM — см. ниже; n8n —
owner-аккаунт n8n остаётся локальным (SSO отсекает неавторизованных).

**Все флоу проверены end-to-end** (dex login → OIDC-код → callback):
OpenWebUI — роль `admin`; LiteLLM — роль `proxy_admin`; n8n — локальный вход
owner'ом тем же email+паролем + гейт Envoy OIDC перед UI.

## Клиенты (staticClients, секреты генерирует terraform)

| id | Redirect URI | Куда |
|----|--------------|------|
| openwebui | `https://chat.<домен>/oauth/oidc/callback` | OpenWebUI |
| litellm | `https://ai.<домен>/sso/callback` | LiteLLM UI |
| n8n | `https://n8n.<домен>/oauth2/callback` | Envoy SecurityPolicy (Envoy Gateway) |

Client-секреты расходятся в Secret'ы `dex-<имя>-client` (key `client-secret`)
в ns соответствующего сервиса — панели берут их через secretKeyRef.

## Установка

```bash
export KUBECONFIG=$(terraform -chdir=infra/01-cluster output -raw kubeconfig_path)
cd infra/02-addons && terraform apply    # чарт + Secret'ы + рендер
kubectl apply -f rendered/httproute-dex.yaml
kubectl apply -f rendered/securitypolicy-n8n.yaml   # SSO для n8n (CRD)
```

Требует: install_envoy_gateway + edge-шлюз (gateway-edge.yaml), cert-manager
(wildcard TLS), external-dns (A-запись auth.<домен>).

## LiteLLM: назначение админа

LiteLLM настроен на `GENERIC_USER_ID_ATTRIBUTE=email`: user_id = email
OIDC-клейма. `PROXY_ADMIN_ID` = email админа dex (Secret
litellm-proxy-admin-id, создаёт terraform из `sso_admin_email`) — при первом
SSO-логине LiteLLM автоматически повышает этого пользователя до proxy_admin
(штатный механизм, проверено по исходникам ui_sso.py). Ручных шагов нет.

## Админские учётки панелей (декларативно)

Единые креды (email из `sso_admin_email`, один пароль на всё — dex и локальные
входы) создаются без ручного входа в UI:

- **dex** — staticPasswords (bcrypt) в Secret dex-config; пароль — Secret
  dex-admin: `kubectl -n dex get secret dex-admin -o jsonpath='{.data.password}' | base64 -d`.
- **OpenWebUI** — init-job `init-openwebui-admin` (addons/openwebui/manifests/):
  первый пользователь через POST /api/v1/auths/signup — становится админом;
  при OIDC-входе OpenWebUI матчит по email существующего пользователя.
- **n8n** — init-job `init-n8n-owner` (addons/n8n/manifests/): POST
  /rest/owner/setup. Локальный вход в n8n — этим же email+паролем (OIDC в
  community-версии нет; вход в n8n дополнительно закрывает SecurityPolicy
  Envoy с OIDC dex — см. ниже).
- **LiteLLM** — админ повышается автоматически при первом SSO-входе
  (PROXY_ADMIN_ID = email, раздел выше); локальная учётка не нужна.

Jobs пересоздаются при смене пароля (terraform). Логи:
`kubectl -n openwebui logs job/init-openwebui-admin`,
`kubectl -n n8n logs job/init-n8n-owner`.

## Грабли

- `terraform plan` всегда показывает обновление Secret dex-config —
  `bcrypt()` перевычисляет хэш с новой солью (функция terraform). Вреда
  нет: рестарт пода — только по чексумме пароля (см. main.tf 02-корня).
- `skipApprovalScreen: true` — иначе dex показывает экран подтверждения
  на каждый вход (для доверенных клиентов панелей не нужен).
- **dex не перечитывает Secret dex-config**: конфиг монтируется как файл без
  watch. После смены клиентов/паролей — `kubectl -n dex rollout restart
  deploy/dex` (иначе новые клиенты получают «Invalid client_id»).
- Секрет `dex-config` содержит bcrypt-хэши и client-секреты: не выводить в
  лог, хэш пароля админа не конвертируется обратно (пароль — в dex-admin).
- При смене `sso_admin_password`/client-секретов перекатываются только
  Secret'ы; сессии панелей сбрасываются (это штатно).
- **OpenWebUI**: `OPENID_PROVIDER_URL` — полный discovery-URL
  (`https://auth.<домен>/.well-known/openid-configuration`): значение
  уходит в `server_metadata_url` authlib как есть, голый домен даёт
  JSONDecodeError на /oauth/oidc/login (проверено).
- **OpenWebUI**: маршрут старта OIDC в v0.11.x — `/oauth/oidc/login`
  (не `/start`, как в старых версиях/доках).
- **OpenWebUI**: админ предсоздан init-job'ом с паролем — без
  `OAUTH_MERGE_ACCOUNTS_BY_EMAIL: true` OIDC-вход в существующий
  email-аккаунт запрещён ("email is already registered").
- **n8n**: `NX_...`/шаблоны не нужны — гейтится SecurityPolicy целиком;
  logout в n8n не завершает сессию Envoy (кука гейта живёт до истечения —
  не критично, при необходимости добавить logoutPath в SecurityPolicy).
- **Повторный логин при переходе между панелями** (вошёл в OpenWebUI, зашёл
  в n8n — снова страница dex-логина): это штатное поведение dex, а не
  ошибка конфигурации. После логина dex не ставит браузерную сессию
  на своём домене вовсе (проверено): флоу идентифицируется
  req-параметром, AuthRequest живёт в storage с `expiry.authRequest`
  (по умолчанию 5 минут). Повторный вход нужен только при первом заходе
  в каждую панель — дальше живёт сессия самой панели.
- Фича Auth Sessions (server-side сессия + cookie на домене dex,
  переиспользование логина между клиентами) — dexidp/dex#4560, PR #4705
  (слит в master 2026-04-02) и фикс #4885 (2026-07-11): **в выпущенных
  релизах её нет** (последний — v2.45.1 от 2026-03-03). Когда релиз
  выйдет — поднять пин чарта (инвариант 5) и включить шаринг сессий.
  Альтернатива до релиза — oauth2-proxy forward-auth с общим
  `--cookie-domain` (панели уходят с нативного OIDC на header-auth);
  для трёх панелей и одного админа усложнение не оправдано.
