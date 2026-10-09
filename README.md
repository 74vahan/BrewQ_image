# BrewQ_image

Docker (compose + Dockerfile backend), Terraform-провижининг сервера в GCP,
nginx на хосте и bootstrap VM для проекта **BrewQ** — заказ напитков в одной
кофейне. Код backend, веб-панели и CI/CD с деплоем — в
[`BrewQ_infra`](https://github.com/74vahan/BrewQ_infra), клиент — в
[`BrewQ_android`](https://github.com/74vahan/BrewQ_android).

Статус: Фаза 1 (планирование) завершена; Фаза 2: Terraform (D2) написан и
проверен без облака, Docker (D1) реализован и проверен локально (задачи D1, D2 в
`BrewQ_infra/memory/07-implementation-plan.md`). Dev-стек из этого репозитория
использован в сквозной проверке Q1 (10.10.2026) вместе с Android-эмулятором и
панелью баристы.

## Что здесь

| Путь | Что |
|---|---|
| `docker/` | `docker-compose.yml` (`db` = MySQL 8.4, `api`), `docker-compose.dev.yml`, `backend.Dockerfile` |
| `terraform/` | VPC, firewall (80/443/22, deny 3306), VM Ubuntu 24.04, bootstrap, nginx, TLS (certbot), outputs |
| `terraform/scripts/` | `bootstrap.sh.tftpl`, `check-templates.sh`, `push-github-secrets.sh` |
| `.github/workflows/image-ci.yml` | `fmt`/`validate`, проверка шаблонов nginx, shellcheck, `docker compose config` — без `apply` |
| `memory/` | Docker, Terraform, решения |

## Контракт между репозиториями (Фаза 1: утверждено, 09.10.2026)

> Эта таблица **дословно одинакова** в README `BrewQ_infra`, `BrewQ_image` и
> `BrewQ_android`. Меняется только во всех трёх сразу.

| Что | Значение | Владелец |
|---|---|---|
| Корень на сервере | `/srv/brewq` (Terraform `app_root`, CI `APP_ROOT`) | BrewQ_image (создаёт bootstrap) |
| Пользователь SSH/деплоя, владелец `/srv/brewq` | `brewq` (Terraform `ssh_user` = секрет `SERVER_USER`); деплою sudo не нужен | BrewQ_image |
| Файл окружения | `/srv/brewq/.env`, режим 600, пишется **один раз** bootstrap'ом | BrewQ_image; деплой только читает и без файла падает |
| Ключи `.env` | `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `BARISTA_PASSWORD`, `BARISTA_TOKEN_SECRET`, `BARISTA_TOKEN_TTL_HOURS`, `BACKEND_PORT`, `PUBLIC_BASE_URL`, `LOG_LEVEL` | BrewQ_image пишет, compose читает |
| Приложение | `/srv/brewq/app/` = `backend/` + `docker/` + `media/`, заменяется целиком каждым деплоем | BrewQ_infra (CI); `docker/` — копия `BrewQ_image/docker/` на `BREWQ_IMAGE_REF` |
| Веб-панель | `/srv/brewq/web/releases/<sha>/`, живой корень — симлинк `/srv/brewq/web/current` | BrewQ_infra (CI); заглушку `releases/bootstrap` ставит BrewQ_image |
| Картинки меню | файлы `/srv/brewq/app/media/menu/*`, URL `/media/menu/<file>`, в БД — относительный путь | файлы — BrewQ_infra, раздача nginx — BrewQ_image |
| Compose | project `brewq`, файл `docker/docker-compose.yml`, сервисы `db` (`mysql:8.4`) и `api` (образ `brewq-api`), том `brewq-db-data`; контекст сборки `api` — `${BACKEND_CONTEXT}` | BrewQ_image |
| Dockerfile ↔ backend | в контексте: `requirements.txt`, пакет `app/`, `alembic.ini`, `alembic/`, `seed/`; старт `python -m app.boot && uvicorn app.main:app --port 8000` | BrewQ_image ↔ BrewQ_infra |
| Порт backend | `127.0.0.1:8081` → `api:8000` (Terraform `backend_port`, env `BACKEND_PORT`) | BrewQ_image публикует, nginx проксирует |
| MySQL | `db:3306` только в docker-сети; наружу не публикуется; firewall deny 3306; dev-оверлей — `127.0.0.1:53306` | BrewQ_image |
| Открытые порты VM | 80, 443 (nginx на хосте), 22 (SSH по ключу) | BrewQ_image |
| nginx | `/etc/nginx/sites-available/brewq`; `/api/` → `127.0.0.1:8081`; `/media/` → диск; `/` → `web/current` (SPA-fallback) | BrewQ_image |
| Health | `GET /api/health` (жив), `GET /api/health/ready` (БД) | BrewQ_infra |
| GitHub `74vahan/BrewQ_infra` | secrets `SERVER_HOST`, `SERVER_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`; variables `APP_ROOT`, `PUBLIC_BASE_URL` — кладёт `BrewQ_image/terraform/scripts/push-github-secrets.sh`; variable `BREWQ_IMAGE_REF` (по умолчанию `main`) — вручную | BrewQ_image → BrewQ_infra |
| API для Android | `<PUBLIC_BASE_URL>/api/`; debug — `http://127.0.0.1:8081/api/` через `adb reverse tcp:8081 tcp:8081` | BrewQ_android |
| Контракт API | `BrewQ_infra/memory/03-api.md`, ошибки `{"error":{"code","message","details"}}`, клиент — заголовок `X-Device-Id` (UUID v4) | BrewQ_infra |
| Локальная раскладка | репозитории — соседи: `DrewQ/BrewQ_infra`, `DrewQ/BrewQ_image`, `DrewQ/BrewQ_android`; `BACKEND_CONTEXT` по умолчанию `../../BrewQ_infra/app/backend` | все |

## Локальный запуск Docker

```bash
cp .env.example .env          # заполнить значения (для dev — любые, пароли без спецсимволов)
docker compose -p brewq-dev --env-file .env \
  -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d --build
curl http://127.0.0.1:8081/api/health/ready      # {"status":"ready"}
docker compose -p brewq-dev down                 # остановить (том БД остаётся; -v — удалить)
```

Нужен соседний клон `BrewQ_infra` (контекст сборки `api`; другой путь —
`BACKEND_CONTEXT` в `.env`). `--env-file` обязателен: каталог проекта —
`docker/`, а не корень репозитория. Если порт 8081 занят, задайте
`BACKEND_PORT` (переменная окружения перекрывает `.env`), например
`BACKEND_PORT=18090 docker compose -p brewq-dev ... up -d`. После смены
`BARISTA_PASSWORD` в `.env` пересоздайте `api`: `... up -d --force-recreate api`
(токены баристы при этом сбрасываются). MySQL в dev-режиме — `127.0.0.1:53306`. Подробности и
отклонения — `memory/01-docker.md`.

## Проверки без облака

```bash
cd terraform
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform -chdir=scripts/render init -backend=false && terraform -chdir=scripts/render validate
scripts/check-templates.sh    # рендер nginx/bootstrap + nginx -t (3 варианта) + bash -n + shellcheck
```

`check-templates.sh` нужен Docker (образы `nginx:1.24-alpine`,
`koalaman/shellcheck`) либо локальные `nginx` и `shellcheck`.

## Развёртывание (когда появится GCP-аккаунт)

Нужны: проект GCP с биллингом и включённым Compute Engine API, `gcloud`,
Terraform >= 1.9, `gh` (для переноса секретов в GitHub).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # project_id; domain и certbot_email — для HTTPS
gcloud auth application-default login
terraform init
terraform plan                                 # посмотреть, что будет создано
terraform apply                                # ~5-10 минут: VM, bootstrap, nginx, TLS
scripts/push-github-secrets.sh                 # REPO по умолчанию 74vahan/BrewQ_infra; нужен gh auth login
terraform output -raw barista_password         # передать баристе
```

- **С доменом** (так и нужно для боевого запуска). `PUBLIC_BASE_URL` попадает
  в `/srv/brewq/.env` один раз при первом запуске VM, поэтому домен нужно
  знать до полного `apply`: сначала
  `terraform apply -target=google_compute_address.external`, возьмите
  `terraform output external_ip`, создайте A-запись домена на этот IP,
  дождитесь DNS, задайте `domain` и `certbot_email` в `terraform.tfvars` и
  только потом полный `terraform apply` — certbot выпустит сертификат, nginx
  переключится на HTTPS, `public_url` будет `https://<domain>`. Если домен
  добавляется к уже работающему серверу — поправьте `PUBLIC_BASE_URL` в
  `/srv/brewq/.env` вручную и перезапустите `api`.
- **Без домена** сайт работает по HTTP на IP: пароль баристы идёт открытым
  текстом, это только для тестов.
- Дальше деплой приложения делает CI `BrewQ_infra` (push в `main` или
  `workflow_dispatch`). `apply` из CI не выполняется: в state лежат ключ
  деплоя и все пароли.
- Логи bootstrap на сервере: `/var/log/brewq-bootstrap.log`.

Ротация пароля баристы — вручную: `ssh brewq@<ip>`, правка `BARISTA_PASSWORD`
в `/srv/brewq/.env`, затем
`docker compose -p brewq --env-file /srv/brewq/.env -f /srv/brewq/app/docker/docker-compose.yml up -d api`
(все выданные токены перестанут действовать). Пароли MySQL так менять нельзя:
они применяются только при инициализации тома.

## Чего здесь нет

- `terraform plan`/`apply` ни разу не выполнялись — GCP-аккаунта ещё нет;
  проверены только `fmt`, `validate`, рендер шаблонов и `nginx -t`.
- Бэкапов БД и мониторинга (риск записан в `memory/03-decisions.md`).
