# Memory — BrewQ_image

Оглавление. Этот репозиторий отвечает за Docker (compose + Dockerfile
backend), Terraform-провижининг сервера в GCP, nginx на хосте, bootstrap VM и
перенос секретов в GitHub. Код backend/панели и CI/CD с деплоем — в
`BrewQ_infra`.

| Файл | Содержание | Статус |
|---|---|---|
| [01-docker.md](01-docker.md) | Compose (`db` + `api`), dev-оверлей, Dockerfile, порты, грабли, что проверено | Фаза 2: реализовано (D1), собрано и запущено против backend |
| [02-terraform-gcp.md](02-terraform-gcp.md) | Ресурсы GCP, переменные, bootstrap, `.env`, nginx, TLS, outputs, секреты GitHub, CI, отклонения от образца, TODO | Фаза 2: реализовано (D2), `apply` не выполнялся |
| [03-decisions.md](03-decisions.md) | Решения и принятые риски | Фаза 1: утверждено |

Перед началом любой работы — прочитать все файлы выше, а также
`BrewQ_infra/memory/07-implementation-plan.md` (задачи D1, D2). После любых
изменений — обновить соответствующий файл и эту таблицу.

## Текущий статус (10.10.2026)

Фаза 1 закрыта. Docker (D1) реализован: образ `api` собирается из
`BrewQ_infra/app/backend`, стек поднимается и `healthy` (подробно — в
`01-docker.md`). Terraform (D2) написан и проверен без облака (`fmt`,
`validate`, `check-templates.sh`); `plan`/`apply` не выполнялись и не будут до
появления GCP-аккаунта. Бэкапов БД нет — TODO в `02-terraform-gcp.md`.

Q1 (10.10.2026): dev-стек этого репозитория (`brewq-dev`, порт 18090) прошёл
сквозную проверку с Android и панелью — см. `01-docker.md` (раздел Q1). Не
проверено: сборка/запуск на настоящей VM (нужен GCP).
Проверка кириллицы (10.10.2026): `BrewQ_infra/ci/check-cyrillic.sh <корень BrewQ_image>`
даёт единственный ERROR: русская строка стаб-страницы баристы (en/ru/hy),
легитимная локализация, в `terraform/scripts/bootstrap.sh.tftpl` (строка 126). Все остальные
русские строки и комментарии в коде, конфигах, скриптах и workflow переведены
на английский — решение в `03-decisions.md` (п. 13).
