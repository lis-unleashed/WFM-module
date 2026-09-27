# Unleashed WFM

Workforce management for the Unleashed pet insurance contact centre (Australia, pre-launch). Aircall calls plus chats, emails and claims → forecast → pooled Erlang C → roster optimiser → clock in/out → timesheets → pay rules → Xero Payroll AU.

**Before starting any new module, read `docs/HANDOVER.md`.** It covers the domain model, algorithms, golden numbers, build order and open decisions.

## Current step

Step 1 of 6: Foundation (repo, migrations, CI running the schema tests, settings, auth skeleton). Update this line as each step is done.

## Stack (proposed; confirm with the user before locking in)

Python 3.12, FastAPI, PostgreSQL 16, SQL-first migrations, OR-Tools/SCIP for rostering, and a web front end in Unleashed branding.

## Commands

None yet. Step 1 creates them: set up the database, run the migrations, run `db/tests/test_schema.sql`, run the app. Add them here as soon as they exist.

## Rules for every session

- **Tests stay green.** `db/tests/test_schema.sql` must report 26 PASS and no FAIL. Run it before every commit that touches the database.
- **Schema changes** are a new numbered migration plus tests. Never edit `0001_initial.sql` after it's deployed.
- **Time**:
  - All timestamps are UTC `timestamptz`, and intervals start on 15-minute boundaries.
  - Opening hours use the staffing pool's timezone (`Australia/Sydney`).
  - Shifts, pay and public holidays use the site's timezone.
- **Append-only tables:** `clock_event`, `clock_event_void`, `audit_log` and `xero_timesheet_export` are never updated or deleted. Corrections are a void plus a re-entry with a reason.
- **Runs are snapshots.** Create a new forecast, staffing or optimiser run rather than editing a published one.
- **Pay**:
  - Store exact minutes and never round against staff.
  - Pay rules are versioned data; never edit a version that has been used.
  - Don't invent award rules. Ask, because they need payroll sign-off.
- **Secrets:** Aircall credentials live in environment variables or a secrets manager. Xero tokens are encrypted by the app, and the newest rotated refresh token is always saved.
- **Rostering:** a roster can't be published until `v_roster_position_check`, `v_shift_meal_break_check` and `v_interval_coverage` show zero failures.
- **Algorithms:** port them from `reference/launch-staffing-planner.html` and `reference/roster_exact_model.py`, then prove the port against the golden numbers in the handover.
- **Open decisions** are listed in the handover (section 9). Ask rather than assume.
- **Writing:** use Australian English. UI follows the Unleashed brand in the handover (section 10). Never recreate the logo.
