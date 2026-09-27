# Unleashed WFM — handover brief

Read this before starting any new module. `CLAUDE.md` holds the rules that apply to every session; this file holds the context, the algorithms, the build order and what's still undecided.

## 1. What we're building

A workforce management system for the Unleashed pet insurance contact centre in Australia, which hasn't launched yet. It runs end to end:

Aircall calls, plus chats, emails and claims from other systems → history → forecast → pooled Erlang C staffing → roster optimiser → staff clock in/out → timesheets → pay classification → Xero Payroll AU.

Opening hours: Monday to Friday 9am–9pm, Saturday and Sunday 10am–3pm, Sydney/Melbourne time (`Australia/Sydney`).

Because there's no call history yet, forecasting starts from business drivers (customers × contact rates) and switches to history-based forecasting after roughly 6–8 weeks of live data.

## 2. What already exists

| Path | What it is | Status |
|---|---|---|
| `db/migrations/0001_initial.sql` | Database schema v0.3: 55 tables, 6 views | Validated on PostgreSQL 16 |
| `db/tests/test_schema.sql` | Builds a realistic week end to end and tries to break every rule | 26 checks, all pass |
| `reference/launch-staffing-planner.html` | Interactive planner with the working forecast, pooled Erlang C and roster engines (JavaScript) | Source of truth for algorithms and golden numbers |
| `reference/roster_exact_model.py` | Exact roster optimiser prototype (OR-Tools + SCIP) used to prove the planner's rosters optimal | Prototype to port |

## 3. Domain model in plain English

- **Site**: where staff work. Its timezone drives shift times, penalty rates and public holidays. It has no default and must be set deliberately.
- **Staffing pool**: the one cross-skilled team. Holds opening hours (in `Australia/Sydney`), the occupancy cap (85%), unplanned shrinkage (10%) and minimum cover (2 people whenever open).
- **Queues**: four kinds of work, each with its own service level. The team picks up the most urgent first.

  | Queue | Target | Started within | Pick-up order |
  |---|---|---|---|
  | Calls and chats | 80% | 20 seconds | 1 |
  | Urgent claims (customer at the vet, waiting for payment or pre-approval) | 90% | 10 minutes | 2 |
  | Emails | 80% | 4 hours | 3 |
  | Routine claims | 80% | 24 hours | 4 |

- **Demand streams**: what gets forecast. Seven of them: calls; chats (handled 2 at once); emails; urgent claims (handled start to finish in one go); and routine claims split into lodge, chase and complete tasks.
- **Work patterns**: contract shapes the roster is built to. Full-time is 37.5 paid hours as five 7.5-hour shifts. Part-time is 20 paid hours over 3–4 days, with shifts of 5–7.5 paid hours. Casual is flexible.
- **Break rule**: shifts over 5 paid hours get a 30-minute unpaid meal break, and nobody works more than 5 hours without one. To be confirmed against the award.
- **Roster**: roster period → optimiser runs → positions ("Part-time 3") → shifts → activities (queue work, meal breaks, training). The optimiser creates positions; people are assigned to them afterwards.
- **Time and attendance**: clock events (append-only), voids, timesheets, timesheet entries (rostered vs actual) and timesheet lines (minutes per pay category per day, which map to Xero earnings rates).

## 4. Architecture (confirmed 27 Sep 2026, for Step 1)

- **Backend**: Python 3.12 with FastAPI, psycopg 3 and plain SQL (no ORM).
- **Database**: PostgreSQL 16, with the `btree_gist` and `citext` extensions.
- **Migrations**: SQL-first, because the schema is hand-written SQL. A small runner in `app/core/migrations.py` applies the numbered `.sql` files in order and refuses to run if an applied file has changed. dbmate was ruled out because it needs a `-- migrate:up` marker in every file, which would have meant editing `0001`.
- **Background jobs**: a scheduler and worker for the Aircall and Xero syncs and the weekly planning run.
- **Solver**: OR-Tools with SCIP for the roster optimiser.
- **Front end**: a web app with a mobile-first staff side (roster, clock in/out) and a manager side (planning, publishing rosters, approvals), in Unleashed branding (section 10).
- **Hosting**: not decided (section 9).

Suggested layout:

```
CLAUDE.md
docs/HANDOVER.md
db/migrations/0001_initial.sql
db/tests/test_schema.sql
reference/launch-staffing-planner.html
reference/roster_exact_model.py
app/        backend: api, planning, integrations, pay
web/        front end
```

## 5. Algorithms to port

The planner's JavaScript is the working reference. Port it faithfully, then prove the port against the golden numbers in section 7.

### 5.1 Driver forecast (pre-launch)

For each stream, weekly items =
active customers × monthly rate % ÷ 100 × (1 + launch uplift %, **contacts only, not claims**) × 12 ÷ 52 × scenario multiplier.

The scenario multiplier is 0.7 for low, 1.0 for expected and 1.3 for high (a ±30% range).

- Split across days by the weekday shares, scaled to 100% across open days only.
- Split each day across its 15-minute slots by the stream's daily pattern, evaluated at each slot's midpoint (hour of day h):
  - Morning peak: `0.15 + 1.0·g(10.75, 1.4) + 0.75·g(14.25, 1.6) + 0.35·g(19, 1.4)`
  - Even: `1`
  - Busier after work: `0.2 + 0.55·g(11, 1.5) + 0.6·g(14, 1.5) + 1.0·g(18.5, 1.4)`
  - where `g(μ, σ) = exp(−0.5·((h − μ)/σ)²)`, normalised so each day sums to 1.
- Claims: the urgent share (20%) goes to the urgent stream; the rest are routine.
- Each routine claim creates 1 lodge task, (chase % × chases per chased claim) chase tasks, and 1 complete task.

### 5.2 Pooled priority Erlang C (per 15-minute interval)

1. Workload per queue, in Erlangs: A = Σ items × handle seconds ÷ 900. For chats, divide the handle time by the concurrency.
2. Sort queues by pick-up order (priority rank, else shortest threshold first).
3. For k = 1..n, take the combined items and workload of queues 1..k. Blended handle time = A × 900 ÷ items. Find the smallest N that meets both conditions:
   - queue k's service level: SL(N) = 1 − C(N, A) · e^(−(N − A) · T ÷ AHT) ≥ target_k, where C comes from the Erlang B recursion `B = A·B ÷ (n + A·B)`, then `C = N·B ÷ (N − A·(1 − B))`;
   - the occupancy cap: A ÷ N ≤ 85%.
4. Required people = max over all k, never below minimum cover.
5. "Set by" = the queue that produced the maximum, or minimum cover (NULL) if the pooled need is at or below the floor.
6. For comparison, record separate-team people: each queue sized on its own, plus the floor for calls and chats. The database enforces pooled ≤ separate.

Known limitation: this assumes people can always switch to the most urgent work. A 20-minute claim completion can't be dropped halfway, so compare against real service levels after launch.

### 5.3 Roster optimiser

Use the exact pattern model in `reference/roster_exact_model.py`:

- Enumerate every part-time weekly pattern: a set of days plus a paid length per day that totals the weekly minutes, within the day-count and shift-length rules and within each day's opening hours. `z[pattern]` = number of people on it.
- Create shift variables per day, paid length, start slot and meal offset. Link them to patterns through each (day, length) pair.
- Full-timers: exactly 5 shifts each, at most one per day per person.
- Coverage: people on the floor, excluding meal breaks, must be at least the requirement in every slot.
- Minimise paid minutes, either for a fixed number of full-timers or letting the solver choose.
- Meal offset window (from shift start): between max(1 h, span − meal − 5 h) and min(5 h, span − meal − 1 h).

Still to build:

- Decompose the solution into named positions and dated shifts with activities.
- Save the optimiser run with its lower bound and `proven_optimal`.
- Save the mix comparison, which shows the paid hours for each full-time/part-time split.

The planner's JavaScript heuristic stays for interactive what-ifs. The backend should use the exact model.

### 5.4 Rule checks before publishing

A roster can only be published when all three of these show zero failures:

- `v_roster_position_check`
- `v_shift_meal_break_check`
- `v_interval_coverage` (no negative gaps)

## 6. Conventions

These are also summarised in `CLAUDE.md`.

- Timestamps are `timestamptz` in UTC. A 15-minute interval is identified by its UTC start, and the database rejects misaligned intervals.
- Opening hours use the staffing pool's timezone. Shifts, pay and public holidays use the site's timezone.
- Forecast, staffing and optimiser runs are immutable snapshots. Create a new run rather than editing a published one.
- Append-only tables: `clock_event`, `clock_event_void`, `audit_log`, `xero_timesheet_export`.
  - Corrections are a void plus a manager entry with a reason.
  - The app's database role should not have UPDATE or DELETE on these tables.
- Approved or exported timesheets are frozen. Reopening one is an audited action.
- Pay is stored in exact minutes and converted to hours only for Xero. Never round against staff.
- Pay rules are versioned data in `pay_rule_version.rules`. Never edit a version that has been used.
- Secrets:
  - Aircall credentials live in environment variables or a secrets manager.
  - Xero tokens are encrypted by the app. Xero refresh tokens rotate, so always save the newest one.
- Schema changes need a new numbered migration plus tests in the style of `test_schema.sql`. Never edit `0001` once it's deployed.
- Use Australian English in the UI and in docs.

## 7. Golden numbers (regression targets)

These come from the planner's default inputs. The backend port must reproduce them.

### Inputs

| Assumption | Value |
|---|---|
| Customers | 10,000 active customers, 50% launch uplift, ±30% range |
| Calls | 10% of customers a month, 7-minute handle time |
| Chats | 4% a month, 12 minutes each, 2 handled at once |
| Emails | 5% a month, 8 minutes each |
| Claims | 3% a month. 20% urgent at 25 minutes start to finish |
| Routine claims | Lodging 10 minutes; 40% chased, 1.5 chases each, 8 minutes per chase; completing 20 minutes |
| Service levels | As in section 3 |
| Team | Minimum 2 on, 85% occupancy cap, 10% absence, 15% breaks and training, 38 hours per FTE |
| Weekday shares | Mon 19, Tue 18, Wed 17, Thu 16, Fri 15, Sat 8, Sun 7 |
| Daily patterns | Morning peak for calls, chats and claims; even for emails |
| Rostering rules | As in section 3 |

### Outputs, expected scenario

| Measure | Value |
|---|---|
| Open 15-minute intervals per week | 280 |
| Weekly volumes | 346 calls, 138 chats, 173 emails, 14 urgent claims, 55 routine claims |
| One cross-skilled team | 6.1 FTE, 178.8 staffed hours a week |
| Separate teams | 13.3 FTE (cross-skilling saves 7.2) |
| Best roster | 1 full-time and 8 part-time, 197.5 paid hours for 178.75 required floor hours. Proven optimal |

### Best rosters, other scenarios

| Scenario | Best roster | Paid hours | Status |
|---|---|---|---|
| Low | 2 full-time and 5 part-time | 175 | Proven optimal |
| High | 2 full-time and 8 part-time | 235 | Best found, not yet proven |

## 8. Build order and when each step is done

1. **Foundation** (done: `make check`; see the README)
   - Repo, a migration runner that applies `0001`, settings and secrets handling, an auth skeleton, and an audit-log helper.
   - CI runs `test_schema.sql` against a fresh PostgreSQL 16 and expects 26 PASS lines and no FAIL.
   - *Done when* a fresh clone sets up the database and runs green with one command.
2. **Planning service**
   - Driver forecast, pooled Erlang C and the roster optimiser, writing to:
     - `forecast_run` and `forecast_interval`;
     - the `staffing_*` tables;
     - `roster_optimisation_run`, positions, shifts and activities.
   - *Done when* it reproduces the golden numbers, the rule-check views show zero failures, and a manager can publish a roster.
3. **Staff app**
   - Log in; see my roster; clock in, clock out, start and end breaks (server time only).
   - Managers correct mistakes by voiding and re-entering, with a reason.
   - *Done when* it works well on a phone and the append-only rules hold.
4. **Timesheets and pay rules**
   - Reconcile clock events against shifts into `timesheet_entry`.
   - Approval flow, with no approving your own timesheet.
   - A pay engine that writes `timesheet_line` rows per day and pay category, recording the `pay_rule_version` used and an explanation.
   - *Done when* award scenarios signed off by the payroll adviser pass as automated tests.
5. **Xero sync**
   - OAuth 2.0 connection.
   - Sync payroll calendars, employees (`xero_employee_id`) and earnings rates (mapped to `pay_category`).
   - Push approved timesheets to Payroll AU as drafts. Pushes are idempotent, and every attempt is logged.
   - *Done when* a parallel pay run matches the manual payroll.
6. **Aircall ingestion** (can run alongside steps 3–5, must be live by launch day so history builds from the first call)
   - API backfill with pagination and rate-limit backoff.
   - Webhooks stored raw first, then processed idempotently.
   - Map numbers to the calls stream and Aircall users to employees.
   - A regular roll-up into `interval_actual`.
   - *Done when* re-running a day's load gives identical results.

After launch:

- Adherence reporting: roster vs clock vs Aircall status.
- History-based forecasting after 6–8 weeks, guided by `v_forecast_accuracy`.
- Connectors that bring chats, emails and claims into `work_item`.

## 9. Open decisions

Don't guess any of these. Ask.

- **Staff location**: where staff are based. This sets the site timezone and the state for public holidays.
- **Pay rules**: which award or enterprise agreement applies, and its penalty and overtime rules. Confirm with the payroll adviser.
- **Xero Payroll AU setup**: pay calendar (weekly or fortnightly), earnings rates, and employees.
- **Aircall**: API credentials, the numbers in use, and whether wrap-up and hold times are available.
- **Other systems**: which ones will handle chats, emails and claims.
- **Hosting and logins**: where the app is hosted, and whether staff log in with Google or Microsoft single sign-on or with email and password.
- **Shift lengths**: full-time shifts of 7.5 paid hours, and a longest part-time shift of 7.5 hours, are assumptions.
- **Public holidays**: whether the centre trades on them.
- **Other rostered time**: how paid rest breaks, training and meetings are scheduled.
- **Urgent claims**: exactly what "started" means for the 10-minute target.

## 10. Brand (for any UI)

- **Primary colours**: Catch Yellow `#EAFF00`, always paired with Siamese Grey `#AAAAA3`.
- **Accents, used sparingly**: Pedigree Pink `#F926F9` for things that need attention; Food-bowl Blue `#08F4D7` for calm contrast.
- **Neutrals**: black and white.
- **Type**: Geologica.
- **Logo**: never recreate it. Unleashed supplies the master artwork.
- **Tone**: plain, warm English, with the humour dialled down for internal tools.
- `reference/launch-staffing-planner.html` shows the pattern: a yellow header band, black boards for data, pink for key prompts.
