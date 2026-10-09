# 01. Docker

Статус: **реализовано** (Фаза 2, задача D1, 09.10.2026); проверка сборки и
запуска — в разделе «Что проверено» ниже.

nginx в Compose **нет** — он на хосте (Terraform, `02-terraform-gcp.md`).
Веб-панель — статика на диске, её контейнера тоже нет. В Compose два сервиса.

## Файлы

```
docker/
  docker-compose.yml                — прод и база для dev
  docker-compose.dev.yml            — оверлей разработки
  backend.Dockerfile                — образ api
  backend.Dockerfile.dockerignore   — фильтр основного контекста (`docker/`); код backend фильтруется выборочными COPY
.env.example                        — имена переменных для локального compose, пустые значения
```

## `docker-compose.yml`

| | `db` | `api` |
|---|---|---|
| Образ | `mysql:8.4` (LTS) | `brewq-api` (сборка: см. «Контекст сборки» ниже) |
| Окружение | `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` (все обязательные), `TZ=UTC` | `DATABASE_URL=mysql+pymysql://${MYSQL_USER}:${MYSQL_PASSWORD}@db:3306/${MYSQL_DATABASE}?charset=utf8mb4`, `BARISTA_PASSWORD`, `BARISTA_TOKEN_SECRET` (обязательные), `BARISTA_TOKEN_TTL_HOURS` (по умолчанию 12), `LOG_LEVEL` (INFO), `MIGRATE_ON_START=true`, `SEED_ON_START=true`, `TZ=UTC` |
| Команда/флаги | `--character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci --default-time-zone=+00:00` | `CMD` образа |
| Порты | **не публикуются** | `127.0.0.1:${BACKEND_PORT:-8081}:8000` |
| Том | `brewq-db-data:/var/lib/mysql` | — |
| Healthcheck | `mysqladmin ping -h 127.0.0.1` | `python -c "urllib.request.urlopen('http://127.0.0.1:8000/api/health/ready')"` |
| Зависимости | — | `depends_on: db: condition: service_healthy` |
| restart | `unless-stopped` | `unless-stopped` |
| Логи | `json-file`, 10 МБ x 3 | `json-file`, 10 МБ x 3 |

- Healthcheck `db` ходит по TCP на `127.0.0.1`: временный сервер, который
  образ поднимает при инициализации тома, слушает только unix-сокет, поэтому
  `healthy` наступает лишь когда БД реально готова. У `api` `start_period: 40s`
  (миграции и сид идут до старта uvicorn).
- `MYSQL_USER` не может быть `root` (ограничение образа mysql).
- Имя проекта — `name: brewq` в файле (и `-p brewq` в командах), поэтому том
  на сервере называется `brewq_brewq-db-data`.
- Обязательные переменные — `${VAR:?...}`: без `.env` compose падает сразу,
  а не поднимает БД с пустым паролем.
- `api` публикуется **только на loopback** — привязка к `0.0.0.0` выставила
  бы API в интернет мимо nginx.

## Контекст сборки `api` (отклонение от буквы спецификации)

Compose считает `build.dockerfile` относительно контекста. Контекст — чужой
каталог (`BACKEND_CONTEXT`), а путь от него до `backend.Dockerfile` разный на
ноутбуке, в CI (`_image/docker`) и на сервере (`/srv/brewq/app/docker`) —
одним значением по умолчанию его не выразить, а новая переменная заставила бы
менять всех вызывающих. Поэтому:

```yaml
build:
  context: .                     # каталог docker/, рядом лежит Dockerfile
  dockerfile: backend.Dockerfile
  additional_contexts:
    backend: ${BACKEND_CONTEXT:-../../BrewQ_infra/app/backend}
```

Backend — именованный контекст `backend`, Dockerfile читает его через
`COPY --from=backend ...`. Для контракта ничего не меняется: единственная
ручка — `BACKEND_CONTEXT`, состав каталога тот же (`requirements.txt`, `app/`,
`alembic.ini`, `alembic/`, `seed/`). `.dockerignore` внутри каталога backend
BuildKit к именованному контексту применяет (проверено). Нужен Compose >= 2.17.

## `docker-compose.dev.yml`

- `db` публикуется на `127.0.0.1:53306` (не 3306 — не конфликтовать с
  установленной MySQL); здесь же backend-тесты (`pytest`) находят БД.
- `api`: `SERVE_MEDIA=true`, `MEDIA_DIR=/media` + том
  `${MEDIA_DIR_HOST:-../../BrewQ_infra/app/media}:/media:ro` — картинки без nginx.
- `uvicorn --reload --reload-dir /srv/api/app` (без `--workers`) и монтирование
  `${BACKEND_CONTEXT}/app` в `/srv/api/app` только для чтения.

## `backend.Dockerfile`

- Две стадии на `python:3.12-slim`: builder собирает колёса из
  `requirements.txt`, runtime ставит их (`--no-index`) без компилятора.
  Backend читается через `COPY --from=backend` (см. «Контекст сборки»).
- Непривилегированный пользователь `app` (uid 10001), `WORKDIR /srv/api`.
- Копируются `app/`, `alembic.ini`, `alembic/`, `seed/` (выборочные COPY);
  `tests/` и `media/` в образ не попадают.
- `ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1`, `EXPOSE 8000`.
- `CMD ["sh","-c","python -m app.boot && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${UVICORN_WORKERS:-2}"]`
  — миграции и сид при старте (флаги env), затем сервер.
- Контракт с backend (что обязано лежать в контексте) — в README, строка
  «Dockerfile ↔ backend».

## Порты

| | Разработка | Сервер |
|---|---|---|
| панель | Vite 5173 (из `BrewQ_infra/app/web`) | 80/443 nginx, статика `web/current` |
| backend | `127.0.0.1:8081` | `127.0.0.1:8081` |
| MySQL | `127.0.0.1:53306` | не публикуется |

## Как поднять локально

```bash
cd BrewQ_image
cp .env.example .env            # заполнить пароли (любые для dev)
docker compose -p brewq-dev --env-file .env \
  -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d --build
curl http://127.0.0.1:8081/api/health/ready
```

## На сервере

Compose запускает деплой из `BrewQ_infra`, а не Terraform:
`BACKEND_CONTEXT=/srv/brewq/app/backend docker compose -p brewq --env-file /srv/brewq/.env -f /srv/brewq/app/docker/docker-compose.yml up -d --build`.
Каталог `docker/` попадает туда как копия этого репозитория на
`BREWQ_IMAGE_REF` (см. `03-decisions.md`).

## Грабли, известные заранее

- **Старый том.** `MYSQL_PASSWORD` применяется только при первой
  инициализации тома; сменить пароль в `.env` поверх существующего тома =
  `Access denied`. Лечится `ALTER USER` внутри контейнера или удалением тома
  (только dev!). Поэтому `.env` на сервере пишется один раз.
- **`PyMySQL[rsa]`.** Без `cryptography` MySQL 8 (`caching_sha2_password`)
  не пускает по не-TLS соединению — зависимость обязана быть в
  `requirements.txt` backend.
- **Пароли в `DATABASE_URL`.** Terraform генерирует их без спецсимволов
  (`special = false`), чтобы URL не требовал экранирования.

## Что проверено (09.10.2026, Docker 29.7, Compose 5.4)

- `docker compose config -q` — база и с dev-оверлеем: ок. В базовом файле у
  `db` нет `ports` (проверено по `config --format json`).
- Сборка и запуск на заглушке backend (минимальный FastAPI с `/api/health*`,
  `app.boot`, `requirements.txt`): оба сервиса `healthy`, `/api/health/ready` →
  `ready`, процесс `api` — uid 10001 (`app`), MySQL опубликована только как
  `127.0.0.1:53306`, `utf8mb4` / `utf8mb4_0900_ai_ci` / `+00:00`, `--reload`
  стартует. Образ не содержит `tests/` и `media/`.
- Против настоящего backend (`BrewQ_infra/app/backend`): `docker compose build
  api` — ок; `up -d` (dev-оверлей) — `db` и `api` `healthy`, миграция
  `0001` и сид меню (12 позиций) прошли в контейнере, `GET /api/health` и
  `/api/health/ready` → 200; повторный `up` на старом томе (только базовый
  файл, `--workers 2`) — сид идемпотентен, `db` без публикации портов.
- На машине разработчика порт 8081 занят контейнером `miasin-api`, поэтому
  проверка шла с `BACKEND_PORT=18081` (переменная окружения перекрывает
  `.env`). Для 8081 никаких отличий, кроме номера порта.

## Q1 (10.10.2026): dev-стек в сквозной проверке

`BACKEND_PORT=18090 docker compose -p brewq-dev --env-file .env -f
docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d` — порт 8081
занят чужим `miasin-api`. После записи `BARISTA_PASSWORD` в `.env` достаточно
`up -d --force-recreate api` (контейнер `db` и том не трогаются), затем
`/api/health/ready` -> `ready`; вход баристы с новым паролем работает. Стек
обслуживал полный цикл заказа с Android-эмулятором и панелью без падений и
перезапусков; после проверки оставлен запущенным.
