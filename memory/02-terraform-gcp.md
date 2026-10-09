# 02. Terraform / GCP

Статус: **Фаза 2: реализовано** (09.10.2026, задача D2; спецификация —
Фаза 1, утверждена). Образец — `MiasinInfra` (структура перенесена,
отличия перечислены ниже и в разделе «Отклонения от образца»).

**GCP-аккаунта у пользователя пока нет.** Terraform написан целиком, но
проверен только `terraform fmt -check`, `terraform validate`
(`init -backend=false`), `scripts/check-templates.sh` (рендер шаблонов,
`nginx -t`, `bash -n`, shellcheck) и функциональной проверкой nginx-конфига
в контейнере. `plan`/`apply` против GCP **не выполнялись** — всё, что
зависит от реального облака (guest agent, ssh, certbot, Docker apt,
bootstrap на живой VM), не проверено до первого `apply`.

Версии (проверены через реестр 09.10.2026): провайдеры `google >= 6.0, < 9.0`
(установлен 8.6.0), `tls 4.4.1`, `random 3.9.1`, `local 2.9.1`, `null 3.3.2`;
Terraform `>= 1.9` (локально 1.9.5). `.terraform.lock.hcl` закоммитить —
хэши записаны для linux/darwin/windows.

## Файлы

```
terraform/
  versions.tf             — terraform >= 1.9, провайдеры google, tls, local, random, null; backend gcs закомментирован
  variables.tf            — все входы (ниже)
  network.tf              — VPC, подсеть 10.30.0.0/24, статические IP, firewall
  secrets.tf              — tls_private_key (SSH деплоя), random_password ×4, locals с путями контракта
  vm.tf                   — google_compute_instance.server + null_resource.wait_for_bootstrap
  nginx.tf                — рендер конфига, null_resource.nginx_site (nginx -t + reload)
  tls.tf                  — check-блоки + null_resource.tls (certbot webroot), HTTPS-вариант конфига
  outputs.tf              — адреса, пути, пароль баристы, значения для GitHub
  terraform.tfvars.example
  backend.hcl.example
  nginx/brewq.conf.tftpl  — конфиг сайта (один шаблон, параметр tls)
  scripts/bootstrap.sh.tftpl
  scripts/check-templates.sh   — рендер шаблонов + nginx -t (локальный nginx или nginx:1.24-alpine, как в Ubuntu 24.04) + bash -n + shellcheck
  scripts/push-github-secrets.sh
  scripts/render/          — мини-модуль для рендера шаблонов без облака (свой .terraform.lock.hcl)
  .gitattributes           — *.sh/*.tf/*.tftpl всегда с LF (git на Windows)
  .terraform.lock.hcl      — закоммитить
.github/workflows/image-ci.yml
```

## Переменные

| Переменная | По умолчанию | Заметки |
|---|---|---|
| `project_id` | — | обязательна |
| `region` / `zone` | `europe-west3` / `europe-west3-c` | как в Miasin; см. вопросы в `03-decisions.md` |
| `instance_name` | `brewq-server` | префикс всех ресурсов |
| `machine_type` | `e2-small` | |
| `disk_size_gb` | `20` | |
| `ssh_user` | `brewq` | = секрет `SERVER_USER` |
| `ssh_source_ranges` / `http_source_ranges` | `["0.0.0.0/0"]` | SSH открыт для GitHub-hosted runner'ов, только ключ |
| `app_root` | `/srv/brewq` | валидация: абсолютный, без `/` в конце |
| `backend_port` | `8081` | |
| `domain`, `domain_aliases`, `certbot_email` | `""`, `[]`, `""` | пусто → HTTP по IP |
| `mysql_database` / `mysql_user` | `brewq` / `brewq` | валидация: `^[a-z][a-z0-9_]{0,31}$`; `mysql_user` не `root` (образ MySQL создаёт root отдельно) |
| `mysql_password`, `mysql_root_password`, `barista_password`, `barista_token_secret` | `""` (sensitive) | пусто → `random_password`; при ручном задании только `A-Za-z0-9_.~-` (значения идут в `.env` и `DATABASE_URL` без экранирования); `barista_password` — не короче 12 символов, `barista_token_secret` — не короче 32 |
| `barista_token_ttl_hours` | `12` | |

App Links (`assetlinks.json`) из Miasin **не переносятся** — в BrewQ нет
ссылок, открывающих приложение.

## Сеть и firewall

- `allow-web`: tcp 80, 443 из `http_source_ranges`.
- `allow-ssh`: tcp 22 из `ssh_source_ranges`.
- `deny-mysql`: tcp 3306, priority 900, из `0.0.0.0/0` — документирует
  намерение (MySQL и так не публикуется).
- Внутри VM — ufw 22/80/443 (вторая линия).

## VM и bootstrap

- Ubuntu 24.04 LTS (`ubuntu-os-cloud/ubuntu-2404-lts-amd64`), тег сети = `instance_name`, ключ `ssh_user` в metadata, `enable-oslogin = FALSE` (иначе политика организации с OS Login игнорирует ssh-keys и ключ деплоя не встанет).
- `ssh_user` получает sudo от GCP guest agent (группа `google-sudoers`) — это нужно только Terraform'у (`nginx -t`, reload, certbot); деплою BrewQ_infra sudo не нужен.
- `lifecycle { ignore_changes = [metadata["startup-script"]] }`: правка
  bootstrap не пересоздаёт машину (на её диске том MySQL).
- `wait_for_bootstrap` ждёт `/srv/brewq/.bootstrap-done` до 15 минут.
- GCP запускает startup-script при **каждой** загрузке: bootstrap идемпотентен и при готовом маркере сразу выходит.

`scripts/bootstrap.sh.tftpl` (лог `/var/log/brewq-bootstrap.log`):

0. Если `.bootstrap-done` уже есть — выход (скрипт GCP гоняет на каждой загрузке).
1. Пакеты: Docker (официальный apt-репозиторий: ключ в `/etc/apt/keyrings`,
   `docker-ce`, `docker-compose-plugin`, `docker-buildx-plugin`), nginx,
   certbot, ufw, fail2ban, rsync, curl.
2. ufw 22/80/443; SSH — без паролей и root через drop-in
   `/etc/ssh/sshd_config.d/10-brewq-hardening.conf` (сортируется раньше
   `60-cloudimg-settings.conf`; sshd берёт первое значение), `sshd -t`.
3. Пользователь `brewq` (создаётся, если guest agent ещё не успел) в группе
   `docker`; каталоги `/srv/brewq/{app,web/releases/bootstrap}` с владельцем
   `brewq` — деплою не нужен sudo.
4. Заглушка панели `web/releases/bootstrap/index.html` на трёх языках
   (en/ru/hy: «BrewQ скоро откроется») и симлинк `web/current` → заглушка —
   без неё nginx не стартует и certbot не пройдёт челлендж до первого деплоя.
   Стили — отдельным файлом `placeholder.css`: CSP nginx (`default-src 'self'`)
   блокирует inline `<style>`.
5. `/srv/brewq/.env` — **только если файла нет**, режим 600, владелец `brewq`:
   ```
   MYSQL_DATABASE=…
   MYSQL_USER=…
   MYSQL_PASSWORD=…
   MYSQL_ROOT_PASSWORD=…
   BARISTA_PASSWORD=…
   BARISTA_TOKEN_SECRET=…
   BARISTA_TOKEN_TTL_HOURS=12
   BACKEND_PORT=8081
   PUBLIC_BASE_URL=http://<ip> | https://<domain>
   LOG_LEVEL=INFO
   ```
   heredoc в кавычках (`<<'ENV'`), переменные shell без `${}` — `.tftpl`
   съедает `${…}` (грабля Miasin). `LOG_LEVEL=INFO` в верхнем регистре — как
   умолчание compose (`${LOG_LEVEL:-INFO}`).
6. Удаление дефолтного сайта nginx; еженедельный `docker system prune` в
   `/etc/cron.weekly/`; маркер `.bootstrap-done`.

## nginx (`nginx/brewq.conf.tftpl`)

Один шаблон, параметр `tls` меняет только начало (`listen 80` либо редирект +
`443 ssl`), тело общее. Порядок `location`:

| location | Что |
|---|---|
| `^~ /.well-known/acme-challenge/` | `root /var/www/certbot` |
| `= /api/health` | прокси без лимита и без access-лога |
| `= /api/barista/login` | прокси, `limit_req zone=login` 5r/m, burst 5 |
| `^~ /api/` | `proxy_pass http://127.0.0.1:8081`, `limit_req zone=api` 10r/s, burst 20 |
| `^~ /media/` | `alias /srv/brewq/app/media/`, `expires 7d` |
| `~* \.(css\|js\|woff2\|svg\|png\|webp\|mp3)$` | `expires 30d` (имена Vite хэшированные) |
| `= /index.html` | `expires -1` |
| `/` | `root /srv/brewq/web/current; try_files $uri $uri/ /index.html` |

- `limit_req_status 429` + `error_page 429 = @rate_limited`, который отдаёт
  `{"error":{"code":"RATE_LIMITED","message":"Too many requests","details":{}}}`
  с `application/json` — клиенты получают тот же конверт.
- Заголовки безопасности — **один раз на уровне `server`**; кэш в location —
  через `expires`, не `add_header` (иначе location теряет CSP — грабля
  Miasin). CSP: `default-src 'self'; img-src 'self' data:; connect-src 'self';
  font-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'self'`.
- `client_max_body_size 16k` (загрузок нет), `proxy_set_header Host /
  X-Real-IP / X-Forwarded-For / X-Forwarded-Proto` — один раз на уровне
  `server`, три API-location наследуют.
- **`^~` у `/api/` и `/media/`** (уточнение к спеке): без него префиксный
  location проигрывает regex статики, и `/media/menu/latte.webp` ушёл бы в
  `root web/current` и дал 404, а `/api/x.png` искался бы на диске.
- TLS-вариант: `listen 443 ssl http2` (директива `http2 on;` — только с nginx
  1.25.1, а в Ubuntu 24.04 версия 1.24; в Miasin на 22.04 она не сработала бы),
  HSTS `max-age=31536000` без `includeSubDomains`.
- `check-templates.sh` рендерит три варианта (HTTP на IP, HTTP на домене,
  HTTPS) и гоняет `nginx -t` над каждым в `nginx:1.24-alpine` (или локальном
  nginx). Поведение (порядок location, лимит, медиа) дополнительно проверено
  в контейнере вручную 09.10.2026.

## TLS

Как в Miasin (`check`-блоки: `domain` без `certbot_email` и пустой `domain`
дают предупреждение при `plan`): HTTP-конфиг всегда первым, затем при заданных `domain` +
`certbot_email` — `certbot certonly --webroot`, HTTPS-конфиг, `nginx -t`,
reload; хук продления `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`.
Без домена сайт работает по HTTP на IP — рабочее, но небезопасное для пароля
баристы состояние (см. `03-decisions.md`).

## Outputs

`external_ip`, `public_url`, `ssh_user`, `app_root`, `backend_port`,
`ssh_command`, `private_key_path`, `deploy_private_key_pem` (sensitive),
`barista_password` (sensitive — оператор передаёт его баристе:
`terraform output -raw barista_password`), `github_secrets` (карта
несекретных значений).

## Перенос секретов в GitHub

`terraform/scripts/push-github-secrets.sh`, запуск после `apply`:
`REPO=74vahan/BrewQ_infra terraform/scripts/push-github-secrets.sh` (нужен
`gh auth login`). Пишет secrets `SERVER_HOST`, `SERVER_USER`,
`SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS` (`ssh-keyscan`) и variables `APP_ROOT`,
`PUBLIC_BASE_URL`. Пароли БД и баристы в GitHub **не переносятся**.

## State

Локальный по умолчанию (`*.tfstate` в `.gitignore`), опционально приватный
GCS-бакет (`backend.hcl.example`). В state — приватный ключ деплоя и все
пароли, поэтому `apply` только с ноутбука, деплоя/`apply` в CI этого
репозитория нет.

## CI этого репозитория (`.github/workflows/image-ci.yml`)

| Задание | Что делает |
|---|---|
| `terraform` | `fmt -check -recursive -diff`, `init -backend=false`, `validate` (корень и `scripts/render`) |
| `templates` | `nginx-light` (на ubuntu-24.04 это 1.24, как на сервере) + `check-templates.sh` с `REQUIRE_SHELLCHECK=1` — `nginx -t` по трём вариантам, `bash -n` и shellcheck отрендеренного bootstrap |
| `shell` | `shellcheck terraform/scripts/*.sh` |
| `compose` | `docker compose config -q` (база и dev); если в `74vahan/BrewQ_infra@main` уже есть `app/backend/requirements.txt` — `docker compose build api` с этим контекстом, иначе `::notice` |

## Ротация пароля баристы (руками, документировать в README)

`ssh brewq@<ip>` → правка `BARISTA_PASSWORD` в `/srv/brewq/.env` →
`docker compose -p brewq --env-file /srv/brewq/.env -f /srv/brewq/app/docker/docker-compose.yml up -d api`.
Все выданные токены перестают действовать (claim `pwv`). Пароли MySQL так
менять нельзя (см. грабли тома в `01-docker.md`).

## Отклонения от образца (Miasin) и от первичной спеки

- Ubuntu 24.04 вместо 22.04; Docker — из официального apt-репозитория, а не
  `get.docker.com`.
- bootstrap идемпотентен (GCP запускает его на каждой загрузке) и сам создаёт
  `ssh_user`, если guest agent не успел; SSH-харднинг — drop-in, а не `sed`
  по `sshd_config` (его перекрывает `60-cloudimg-settings.conf`).
- `enable-oslogin = FALSE` в metadata VM.
- `^~` у `/api/` и `/media/`, `http2` в `listen` — см. раздел nginx.
- Валидация секретов по символам и длине (см. «Переменные»).
- `push-github-secrets.sh`: `REPO` по умолчанию `74vahan/BrewQ_infra`.
- `.gitattributes` (LF) в `terraform/`.
- Проверка nginx на ветке 1.24, а не 1.27: ловит директивы, которых на
  сервере нет.

## TODO

- **Бэкапы БД отсутствуют** (отложено отдельной задачей): том MySQL на диске
  VM — единственная копия. Кандидат — ежедневный `mysqldump` в приватный
  GCS-бакет (cron в bootstrap + сервисный аккаунт с правом записи в бакет).
- **`PUBLIC_BASE_URL` в `.env` пишется один раз.** Домен, добавленный после
  первого запуска VM, не попадёт в `.env` сам: либо сначала
  `apply -target=google_compute_address.external`, A-запись и только потом
  полный `apply` (порядок описан в README), либо правка `.env` вручную.
- До первого `apply` не проверены: поведение guest agent с заранее созданным
  `brewq`, установка Docker из apt на живой VM, certbot webroot, права nginx
  (`www-data`) на `/srv/brewq/web` и `/srv/brewq/app/media`.
