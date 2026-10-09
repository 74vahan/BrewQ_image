# BrewQ backend image (FastAPI + Alembic + menu seed).
#
# The backend source is the NAMED build context `backend` (see api.build in
# docker-compose.yml): BrewQ_infra/app/backend locally, /srv/brewq/app/backend
# on the server. Contract with the backend (BrewQ_image/README.md): the context
# holds requirements.txt, the app/ package, alembic.ini, alembic/ and seed/.

# ---- builder: wheels, so the runtime image needs no compiler ----------------
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /wheels

# requirements first: code edits do not invalidate the dependency layer.
COPY --from=backend requirements.txt ./
RUN pip wheel --wheel-dir /wheels -r requirements.txt

# ---- runtime ----------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Unprivileged user; uid is fixed so volume ownership is predictable.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /srv/api --no-create-home --shell /usr/sbin/nologin app

WORKDIR /srv/api

COPY --from=builder /wheels /wheels
COPY --from=backend requirements.txt ./
RUN pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

# Only what runs: tests/, media/, caches and dotfiles never get in.
COPY --from=backend --chown=app:app app ./app
COPY --from=backend --chown=app:app alembic.ini ./alembic.ini
COPY --from=backend --chown=app:app alembic ./alembic
COPY --from=backend --chown=app:app seed ./seed

USER app

EXPOSE 8000

# Migrations and seed (flags MIGRATE_ON_START / SEED_ON_START) run in
# app.boot, then the server replaces the shell as PID 1 (clean SIGTERM).
CMD ["sh", "-c", "python -m app.boot && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${UVICORN_WORKERS:-2}"]
