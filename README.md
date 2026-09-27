# Unleashed WFM

Workforce management for the Unleashed pet insurance contact centre: forecasting, pooled Erlang C staffing, rostering, clock in and out, timesheets, pay rules and Xero Payroll AU.

Start with [`docs/HANDOVER.md`](docs/HANDOVER.md) for the domain, algorithms, build order and open decisions, and [`CLAUDE.md`](CLAUDE.md) for the rules every change follows.

## Getting started

You need [uv](https://docs.astral.sh/uv/) and either Docker or a PostgreSQL 16 server. The `psql` client is used if it's installed; otherwise the SQL tests use the one inside the Docker database.

```sh
make check   # everything CI runs; starts PostgreSQL with Docker if nothing is running
make db      # set up a local database and its logins, then migrate it
make run     # start the API on http://localhost:8000 (API docs at /docs)
```

A fresh clone needs no configuration. To change a setting, copy `.env.example` to `.env` and edit it.

In Claude Code on the web, `.claude/hooks/session-start.sh` starts the container's PostgreSQL 16 and installs the dependencies, so `make check` works straight away.

## Commands

The `make` targets are shortcuts for `uv run ...` commands, so everything works without make too.

| Command | What it does |
|---|---|
| `make check` | Lint, types, migration guard, SQL tests and Python tests: what CI runs |
| `uv run wfm db ensure-server` | Check PostgreSQL is running, and start the Docker one if it isn't |
| `uv run wfm db setup` | Create the local database and its logins, then migrate it (`make db`) |
| `uv run wfm db migrate` | Apply pending migrations, using `WFM_MIGRATION_DATABASE_URL` |
| `uv run wfm db status` | List applied and pending migrations |
| `uv run wfm db test [-v] [file ...]` | Run the SQL tests, each in a brand-new database (`-v` shows what they print) |
| `uv run wfm db check-frozen` | Fail if a migration that's already on `main` has been edited |
| `uv run wfm generate-key` | Make a key for `WFM_TOKEN_ENCRYPTION_KEYS` |
| `uv run pytest` | The Python tests (they need PostgreSQL too) |

## How the database is looked after

- **Migrations** are the numbered files in `db/migrations`. Each runs once, in one transaction, and its checksum is recorded in `schema_migrations`. The runner refuses to continue if an applied file has changed, so every change goes in a new migration. A migration that adds tables or views ends with `SELECT grant_app_privileges();`.
- **SQL tests** in `db/tests` each get a brand-new database, migrated as the schema owner. Each check prints `PASS: ...`, and `db/tests/expected_passes.toml` says how many each file must print (`test_schema.sql` = 26). New test files go in that list too.
- **Roles.** Migrations run as the schema owner, `wfm_owner`. The app logs in as a member of `wfm_app`, which can read and write ordinary tables but can only read and add to the append-only ones: `clock_event`, `clock_event_void`, `audit_log` and `xero_timesheet_export`.
- **Time.** App connections work in UTC. Local times are always converted with the staffing pool's or the site's timezone.

## Settings

All settings are `WFM_*` environment variables, and `.env.example` describes each one. Local and test environments have working defaults. Staging and production have none, and refuse to start with the dev login switched on, insecure cookies, or origins that aren't `https://`.

## Signing in

How staff sign in (Google or Microsoft single sign-on, or email and password) is still to be decided. Until then, local and test environments have `POST /auth/dev-login`, which signs in any active user by email address. Sessions are stored in the database, and only a hash of each cookie token is kept. A session ends after 6 hours without use or 12 hours in total, and at once if the user is deactivated. The limits are settings.

## Deploying

Hosting isn't decided yet (handover section 9). Whichever platform is chosen:

1. A database administrator creates the roles and the database once, with real passwords from the secrets manager:

   ```sql
   CREATE ROLE wfm_owner LOGIN PASSWORD '...';
   CREATE ROLE wfm_app NOLOGIN;
   CREATE ROLE wfm_api LOGIN PASSWORD '...' IN ROLE wfm_app;
   CREATE DATABASE wfm OWNER wfm_owner;
   ```

2. Set `WFM_ENV=production`, `WFM_DATABASE_URL` (logging in as `wfm_api`), `WFM_MIGRATION_DATABASE_URL` (as `wfm_owner`) and `WFM_ALLOWED_ORIGINS`. From Step 5, also set `WFM_TOKEN_ENCRYPTION_KEYS`.
3. For each release, run `wfm db migrate`, then start the app with `uvicorn app.main:create_app --factory --proxy-headers`. Behind a load balancer, set uvicorn's `--forwarded-allow-ips` so the audit log records real client addresses. Point the platform's health checks at `/healthz` (running) and `/readyz` (database reachable and fully migrated).

## Layout

```
app/core/        settings, database, migrations, sessions, audit log, encryption
app/api/         the web API: health checks and signing in
app/cli.py       the `wfm` command
db/migrations/   numbered SQL migrations (0001 is the validated schema)
db/tests/        SQL tests and their expected PASS counts
tests/           Python tests
reference/       the planner and optimiser prototypes to port in Step 2
docs/            the handover brief
```
