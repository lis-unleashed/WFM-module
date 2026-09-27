# Unleashed WFM

Workforce management for the Unleashed pet insurance contact centre (Australia, pre-launch). Aircall calls plus chats, emails and claims → forecast → pooled Erlang C → roster optimiser → clock in/out → timesheets → pay rules → Xero Payroll AU.

**Before starting any new module, read `docs/HANDOVER.md`.** It covers the domain model, algorithms, golden numbers, build order and open decisions.

## Current step

Step 2 of 6: Planning service (driver forecast, pooled Erlang C, roster optimiser). Step 1, Foundation, is done. Update this line as each step is done.

## Stack (confirmed 27 Sep 2026)

- Python 3.12 with uv, FastAPI, and psycopg 3 with plain SQL (no ORM).
- PostgreSQL 16, with SQL-first migrations applied by the runner in `app/core/migrations.py`.
- pytest, ruff and mypy; CI on GitHub Actions.
- Still to come: OR-Tools/SCIP for rostering (Step 2), and a web front end in Unleashed branding (framework not chosen yet).

## Commands

- `make check`: everything CI runs (lint, types, migration guard, SQL tests, Python tests). It starts PostgreSQL with Docker if nothing is running.
- `make db`: create the local database and its logins, then migrate (`uv run wfm db setup`).
- `make run`: start the API on http://localhost:8000 (API docs at `/docs`).
- `uv run wfm db test [-v] [file ...]`: run the SQL tests, each in a brand-new database.
- `uv run wfm db migrate` and `uv run wfm db status`: apply pending migrations, or list them.
- `uv run pytest tests/test_api.py -k signing_out`: one Python test file, or the tests matching a name.

In Claude Code on the web, `.claude/hooks/session-start.sh` starts PostgreSQL 16 and installs the dependencies at the start of each session.

## Rules for every session

- **Tests stay green.** `make check` must pass before every commit. It includes `db/tests/test_schema.sql`, which must report 26 PASS and no FAIL. Every SQL test file's count is in `db/tests/expected_passes.toml`; raise the count when you add checks.
- **Schema changes** are a new numbered migration plus tests. Never edit `0001_initial.sql` after it's deployed; the runner and CI refuse edits to any migration already on `main`. A migration that adds tables or views ends with `SELECT grant_app_privileges();`.
- **Database roles:** migrations run as the schema owner (`wfm_owner`). The app logs in as a member of `wfm_app`, and never as the owner or a superuser.
- **Auth:** routes that change data do it inside `with conn.transaction():`. Check roles with `require_role(...)`, naming every role allowed. Record significant actions (sign-ins, approvals, publishing, corrections) with `audit.record()` in the same transaction. How people sign in is still open (handover section 9); the dev-only login stands in until then.
- **Time**:
  - All timestamps are UTC `timestamptz`, and intervals start on 15-minute boundaries.
  - Opening hours use the staffing pool's timezone (`Australia/Sydney`).
  - Shifts, pay and public holidays use the site's timezone.
- **Append-only tables:** `clock_event`, `clock_event_void`, `audit_log` and `xero_timesheet_export` are never updated or deleted. Corrections are a void plus a re-entry with a reason. `wfm_app` can only read and insert them (`db/tests/test_0002_app_role.sql`).
- **Runs are snapshots.** Create a new forecast, staffing or optimiser run rather than editing a published one.
- **Pay**:
  - Store exact minutes and never round against staff.
  - Pay rules are versioned data; never edit a version that has been used.
  - Don't invent award rules. Ask, because they need payroll sign-off.
- **Secrets:** settings come from `WFM_*` environment variables (see `.env.example`), and secrets are `SecretStr`. Aircall credentials live in environment variables or a secrets manager. Xero tokens are encrypted by the app (`app/core/crypto.py`), and the newest rotated refresh token is always saved.
- **Rostering:** a roster can't be published until `v_roster_position_check`, `v_shift_meal_break_check` and `v_interval_coverage` show zero failures.
- **Algorithms:** port them from `reference/launch-staffing-planner.html` and `reference/roster_exact_model.py`, then prove the port against the golden numbers in the handover.
- **Open decisions** are listed in the handover (section 9). Ask rather than assume.
- **Writing:** use Australian English. UI follows the Unleashed brand in the handover (section 10). Never recreate the logo.
