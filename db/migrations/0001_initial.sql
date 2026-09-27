-- =====================================================================
--  WFM SYSTEM — DATABASE SCHEMA  (v0.3)
--  Aircall calls + chats, emails and claims → history → forecast
--    → pooled Erlang C → roster optimiser → clock in/out → timesheets
--    → pay classification → Xero Payroll AU
--
--  Target: PostgreSQL 15+  (validated on PostgreSQL 16)
--
--  CONVENTIONS
--  * Every timestamp is timestamptz, stored in UTC. Anything that depends
--    on local time uses a named IANA timezone: opening hours use the
--    staffing pool's timezone (Sydney/Melbourne time); shifts, penalty
--    rates and public holidays use the site's timezone, where staff work.
--  * A 15-minute interval is identified by its UTC start time. Australian
--    offsets are whole or half hours, so UTC 15-minute boundaries line up
--    with local ones, including across daylight saving.
--  * One cross-skilled team (a staffing pool) works several queues. Each
--    queue has its own service level and priority. Staffing is calculated
--    for the whole pool, with the most urgent work picked up first.
--  * Demand streams are what gets forecast: calls and chats are two streams
--    of one queue; routine claims have lodge, chase and complete streams.
--  * Before launch, forecasts are built from business drivers (customers x
--    contact rate) spread by an arrival profile. History takes over later.
--  * Forecast, staffing and roster optimiser runs are snapshots. Every
--    number can be traced back to the exact inputs that produced it.
--  * Time & attendance records are append-only. Mistakes are corrected by
--    voiding and re-entering, never by editing (7-year record keeping).
--  * Status fields use text + CHECK constraints rather than ENUM types,
--    so new values can be added without a type migration.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- lets EXCLUDE constraints combine ids with time ranges
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email addresses


-- ---------------------------------------------------------------------
--  HELPER FUNCTIONS
-- ---------------------------------------------------------------------

-- Keeps updated_at current (attached to every table with that column at the end of this file)
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Blocks UPDATE / DELETE / TRUNCATE on append-only tables.
-- Also revoke UPDATE and DELETE from the application's database role, so
-- this is enforced by permissions as well as by the trigger.
CREATE FUNCTION prevent_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only. Record a correction instead of changing history.', TG_TABLE_NAME;
END $$;


-- =====================================================================
--  1. ORGANISATION & REFERENCE DATA
-- =====================================================================

-- A site is where staff work. Its timezone drives shift times, penalty
-- rates and public holidays, so it has no default: set it deliberately.
CREATE TABLE site (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL UNIQUE,
  timezone        text NOT NULL,             -- IANA zone name, e.g. Australia/Adelaide
  state_code      text NOT NULL
                  CHECK (state_code IN ('ACT','NSW','NT','QLD','SA','TAS','VIC','WA')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Public holidays by state. Most run all day, but SA also has part-day
-- public holidays (7pm to midnight on Christmas Eve and New Year's Eve),
-- so each holiday carries its own local start and end time.
CREATE TABLE public_holiday (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  state_code      text NOT NULL,
  holiday_date    date NOT NULL,
  name            text NOT NULL,
  starts_local    time NOT NULL DEFAULT '00:00',
  ends_local      time NOT NULL DEFAULT '24:00',
  CHECK (ends_local > starts_local),
  UNIQUE (state_code, holiday_date, starts_local)
);

CREATE TABLE team (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id         bigint NOT NULL REFERENCES site(id),
  name            text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, name)
);

CREATE TABLE skill (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL UNIQUE,         -- e.g. 'Sales', 'Billing', 'Tech support L1'
  description     text
);

-- A staffing pool is one cross-skilled team that works several queues.
-- Opening hours, the occupancy cap and minimum cover belong here, because
-- the whole team is staffed together.
CREATE TABLE staffing_pool (
  id                              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id                         bigint NOT NULL REFERENCES site(id),
  name                            text NOT NULL,
  timezone                        text NOT NULL DEFAULT 'Australia/Sydney',   -- opening hours are set in this zone
  max_occupancy_pct               numeric(5,2) NOT NULL DEFAULT 85
                                  CHECK (max_occupancy_pct > 0 AND max_occupancy_pct <= 100),
  -- Unplanned absence only (sick leave, no-shows). Meal breaks, training and
  -- meetings are rostered explicitly as shift activities.
  default_unplanned_shrinkage_pct numeric(5,2) NOT NULL DEFAULT 10
                                  CHECK (default_unplanned_shrinkage_pct >= 0 AND default_unplanned_shrinkage_pct < 100),
  min_agents_open                 integer NOT NULL DEFAULT 2 CHECK (min_agents_open >= 0),  -- always on while open
  is_active                       boolean NOT NULL DEFAULT true,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, name)
);

-- A queue is a kind of work with its own service level: calls and chats,
-- emails, urgent claims (customer at the vet), routine claims.
CREATE TABLE queue (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staffing_pool_id        bigint NOT NULL REFERENCES staffing_pool(id),
  name                    text NOT NULL,
  skill_id                bigint REFERENCES skill(id),     -- people need this skill to take the work
  sl_target_pct           numeric(5,2) NOT NULL DEFAULT 80
                          CHECK (sl_target_pct > 0 AND sl_target_pct <= 100),
  -- How soon work must be started, in seconds: 20 for calls, 600 for urgent
  -- claims, 14400 (4 hours) for emails, 86400 (24 hours) for routine claims
  sl_threshold_seconds    integer NOT NULL DEFAULT 20 CHECK (sl_threshold_seconds >= 0),
  -- 1 = picked up first. NULL = order by sl_threshold_seconds.
  priority_rank           smallint CHECK (priority_rank > 0),
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staffing_pool_id, name)
);

-- A demand stream is one kind of work arriving in a queue, with its own
-- volume and handle time. This is the level that gets forecast.
CREATE TABLE demand_stream (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue_id                bigint NOT NULL REFERENCES queue(id),
  channel                 text NOT NULL CHECK (channel IN ('voice','chat','email','claim')),
  -- contact = a call, chat or email. Claims are split into tasks:
  -- end_to_end (urgent, handled in one go), or lodge / chase / complete.
  task                    text NOT NULL DEFAULT 'contact'
                          CHECK (task IN ('contact','end_to_end','lodge','chase','complete')),
  name                    text NOT NULL,
  -- Chats handled at once by one person: at 2, each chat takes half a person
  concurrency             numeric(3,1) NOT NULL DEFAULT 1 CHECK (concurrency >= 1 AND concurrency <= 6),
  -- Wrap-up allowance added to talk time when the source system doesn't record it
  default_acw_seconds     integer NOT NULL DEFAULT 0 CHECK (default_acw_seconds >= 0),
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (queue_id, channel, task),
  UNIQUE (queue_id, name),
  CHECK (channel = 'chat' OR concurrency = 1),
  CHECK ((channel = 'claim') = (task <> 'contact'))
);

-- Aircall phone numbers, synced from the Aircall API. Each feeds the voice
-- stream of a queue.
CREATE TABLE aircall_number (
  aircall_number_id   bigint PRIMARY KEY,                       -- Aircall's own ID
  name                text,
  digits              text,
  demand_stream_id    bigint REFERENCES demand_stream(id),      -- NULL = not forecast (e.g. outbound-only line)
  synced_at           timestamptz NOT NULL DEFAULT now()
);

-- Regular opening hours for a staffing pool, in the pool's timezone.
-- Dated, so later changes (e.g. extending hours after launch) keep history.
CREATE TABLE opening_hours (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staffing_pool_id    bigint NOT NULL REFERENCES staffing_pool(id),
  day_of_week         smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),  -- ISO: 1 = Monday
  opens_local         time NOT NULL,
  closes_local        time NOT NULL,
  effective_from      date NOT NULL,
  effective_to        date,              -- NULL = current
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (closes_local > opens_local),
  CHECK (extract(minute FROM opens_local)::int  % 15 = 0 AND extract(second FROM opens_local)  = 0),
  CHECK (extract(minute FROM closes_local)::int % 15 = 0 AND extract(second FROM closes_local) = 0),
  CHECK (effective_to IS NULL OR effective_to >= effective_from),
  EXCLUDE USING gist (staffing_pool_id WITH =, day_of_week WITH =,
                      daterange(effective_from, effective_to, '[]') WITH &&)
);

-- One-off changes to the regular hours: public holidays, closures,
-- extended hours for launch day.
CREATE TABLE opening_hours_exception (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staffing_pool_id    bigint NOT NULL REFERENCES staffing_pool(id),
  exception_date      date NOT NULL,
  is_closed           boolean NOT NULL,
  opens_local         time,
  closes_local        time,
  reason              text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staffing_pool_id, exception_date),
  CHECK ((is_closed AND opens_local IS NULL AND closes_local IS NULL)
      OR (NOT is_closed AND opens_local IS NOT NULL AND closes_local IS NOT NULL
          AND closes_local > opens_local)),
  CHECK (opens_local  IS NULL OR (extract(minute FROM opens_local)::int  % 15 = 0 AND extract(second FROM opens_local)  = 0)),
  CHECK (closes_local IS NULL OR (extract(minute FROM closes_local)::int % 15 = 0 AND extract(second FROM closes_local) = 0))
);

-- Every open 15-minute interval for a staffing pool between two local
-- dates, after applying exceptions. Local times are converted to UTC with
-- the pool's timezone, so daylight saving is handled.
CREATE FUNCTION open_intervals(p_pool_id bigint, p_from date, p_to date)
RETURNS TABLE (interval_start timestamptz, local_date date, local_time time)
LANGUAGE sql STABLE AS $$
  WITH pool AS (
    SELECT timezone AS tz FROM staffing_pool WHERE id = p_pool_id
  ),
  days AS (
    SELECT d::date AS local_date
    FROM generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  windows AS (
    SELECT days.local_date,
           CASE WHEN ex.id IS NOT NULL THEN ex.opens_local  ELSE oh.opens_local  END AS opens_local,
           CASE WHEN ex.id IS NOT NULL THEN ex.closes_local ELSE oh.closes_local END AS closes_local
    FROM days
    LEFT JOIN opening_hours_exception ex
           ON ex.staffing_pool_id = p_pool_id AND ex.exception_date = days.local_date
    LEFT JOIN opening_hours oh
           ON oh.staffing_pool_id = p_pool_id
          AND oh.day_of_week = extract(isodow FROM days.local_date)
          AND days.local_date >= oh.effective_from
          AND (oh.effective_to IS NULL OR days.local_date <= oh.effective_to)
  )
  SELECT (slot AT TIME ZONE pool.tz) AS interval_start,
         w.local_date,
         slot::time AS local_time
  FROM windows w
  CROSS JOIN pool
  CROSS JOIN LATERAL generate_series(w.local_date + w.opens_local,
                                     w.local_date + w.closes_local - interval '15 minutes',
                                     interval '15 minutes') AS slot
  WHERE w.opens_local IS NOT NULL
  ORDER BY 1
$$;

-- The shapes of working week the roster optimiser builds to, e.g.
-- full-time: 37.5 paid hours as five 7.5-hour shifts;
-- part-time: 20 paid hours over 3 or 4 days, shifts of 5 to 7.5 hours.
CREATE TABLE work_pattern (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name                        text NOT NULL UNIQUE,
  employment_type             text NOT NULL CHECK (employment_type IN ('full_time','part_time','casual')),
  weekly_min_paid_minutes     integer NOT NULL,
  weekly_max_paid_minutes     integer NOT NULL,
  min_days_per_week           smallint NOT NULL,
  max_days_per_week           smallint NOT NULL,
  min_shift_paid_minutes      integer NOT NULL,
  max_shift_paid_minutes      integer NOT NULL,
  is_active                   boolean NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CHECK (weekly_min_paid_minutes >= 0 AND weekly_min_paid_minutes <= weekly_max_paid_minutes),
  CHECK (weekly_min_paid_minutes % 15 = 0 AND weekly_max_paid_minutes % 15 = 0),
  CHECK (min_shift_paid_minutes > 0 AND min_shift_paid_minutes <= max_shift_paid_minutes),
  CHECK (min_shift_paid_minutes % 15 = 0 AND max_shift_paid_minutes % 15 = 0),
  CHECK (min_days_per_week BETWEEN 0 AND 7 AND max_days_per_week BETWEEN GREATEST(min_days_per_week, 1) AND 7),
  -- The rules have to be able to add up
  CHECK (min_days_per_week * min_shift_paid_minutes <= weekly_max_paid_minutes),
  CHECK (weekly_min_paid_minutes <= max_days_per_week * max_shift_paid_minutes)
);

-- Meal break rules used when rostering and checking shifts. Confirm the
-- values against the award or agreement that covers your team.
CREATE TABLE break_rule (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id                 bigint NOT NULL REFERENCES site(id),
  effective_from          date NOT NULL,
  effective_to            date,
  unpaid_meal_minutes     integer NOT NULL DEFAULT 30
                          CHECK (unpaid_meal_minutes >= 0 AND unpaid_meal_minutes % 15 = 0),
  -- Shifts with more paid time than this get a meal break, and nobody works
  -- longer than this without one
  meal_after_minutes      integer NOT NULL DEFAULT 300
                          CHECK (meal_after_minutes > 0 AND meal_after_minutes % 15 = 0),
  notes                   text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  CHECK (effective_to IS NULL OR effective_to >= effective_from),
  EXCLUDE USING gist (site_id WITH =, daterange(effective_from, effective_to, '[]') WITH &&)
);

-- Xero payroll calendars (weekly, fortnightly...), synced from Xero.
-- Timesheet periods must line up with the employee's calendar.
CREATE TABLE xero_payroll_calendar (
  xero_payroll_calendar_id  uuid PRIMARY KEY,
  name                      text NOT NULL,
  calendar_type             text NOT NULL,             -- as returned by Xero, e.g. WEEKLY, FORTNIGHTLY
  reference_start_date      date NOT NULL,             -- a known period start; later periods step from here
  payment_date              date,
  synced_at                 timestamptz NOT NULL DEFAULT now()
);

-- Where each block of worked hours gets paid in Xero. Your pay engine
-- sorts hours into these categories; Xero applies the dollar rates.
CREATE TABLE pay_category (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                    text NOT NULL UNIQUE,       -- e.g. ORD, CAS_ORD, OT_150, OT_200, SAT, SUN, PH, EVE
  name                    text NOT NULL,
  xero_earnings_rate_id   uuid UNIQUE,                -- the Xero earnings rate these hours are paid under
  rate_multiplier         numeric(5,3),               -- informational only; Xero holds the real rate
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- A family of pay rules, e.g. "Call centre agents – casual", implementing
-- a particular modern award or enterprise agreement.
CREATE TABLE pay_rule_set (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL UNIQUE,
  instrument      text NOT NULL,       -- the award / agreement this set implements
  description     text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Dated versions of a rule set. The pay engine picks the version in force
-- on each work date. Once a version has been used, never edit it: create
-- a new version, so past timesheets can always be re-explained.
CREATE TABLE pay_rule_version (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pay_rule_set_id   bigint NOT NULL REFERENCES pay_rule_set(id),
  version           integer NOT NULL,
  effective_from    date NOT NULL,
  effective_to      date,                -- NULL = still in force
  -- Configuration read by the pay-classification engine: ordinary-hours
  -- span, daily and weekly overtime thresholds, weekend and public-holiday
  -- categories, minimum engagement, and so on.
  rules             jsonb NOT NULL,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pay_rule_set_id, version),
  CHECK (effective_to IS NULL OR effective_to >= effective_from),
  EXCLUDE USING gist (pay_rule_set_id WITH =,
                      daterange(effective_from, effective_to, '[]') WITH &&)
);


-- =====================================================================
--  2. PEOPLE & ACCESS
-- =====================================================================

CREATE TABLE employee (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id                   bigint NOT NULL REFERENCES site(id),
  team_id                   bigint REFERENCES team(id),
  employee_code             text UNIQUE,
  first_name                text NOT NULL,
  last_name                 text NOT NULL,
  email                     citext NOT NULL UNIQUE,
  mobile                    text,
  start_date                date NOT NULL,
  end_date                  date,
  status                    text NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','inactive','terminated')),
  -- Links to the outside systems
  aircall_user_id           bigint UNIQUE,   -- matches calls and agent status to this person
  xero_employee_id          uuid UNIQUE,     -- matches timesheets to Xero Payroll AU
  xero_payroll_calendar_id  uuid REFERENCES xero_payroll_calendar(xero_payroll_calendar_id),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date IS NULL OR end_date >= start_date)
  -- Employees are never deleted (record keeping). Set status instead.
);

-- Login accounts. Managers, payroll and admins may have no employee row.
CREATE TABLE app_user (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id     bigint UNIQUE REFERENCES employee(id),
  email           citext NOT NULL UNIQUE,
  password_hash   text,        -- argon2id or bcrypt via your auth library; NULL if using SSO
  role            text NOT NULL DEFAULT 'staff'
                  CHECK (role IN ('staff','manager','payroll','admin')),
  is_active       boolean NOT NULL DEFAULT true,
  last_login_at   timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Which managers look after (and approve timesheets for) which teams
CREATE TABLE team_manager (
  team_id         bigint NOT NULL REFERENCES team(id),
  app_user_id     bigint NOT NULL REFERENCES app_user(id),
  PRIMARY KEY (team_id, app_user_id)
);

-- Employment terms over time. Pay rules depend on these, and history
-- must be kept, so changes add a new row rather than editing the old one.
CREATE TABLE employee_contract (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id         bigint NOT NULL REFERENCES employee(id),
  effective_from      date NOT NULL,
  effective_to        date,          -- NULL = current
  employment_type     text NOT NULL
                      CHECK (employment_type IN ('full_time','part_time','casual')),
  classification      text,          -- award classification level
  pay_rule_set_id     bigint NOT NULL REFERENCES pay_rule_set(id),
  work_pattern_id     bigint REFERENCES work_pattern(id),   -- the working week they're rostered to
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (effective_to IS NULL OR effective_to >= effective_from),
  CHECK (employment_type = 'casual' OR work_pattern_id IS NOT NULL),
  -- No two contracts for the same person can overlap in time
  EXCLUDE USING gist (employee_id WITH =,
                      daterange(effective_from, effective_to, '[]') WITH &&)
);

CREATE TABLE employee_skill (
  employee_id     bigint NOT NULL REFERENCES employee(id),
  skill_id        bigint NOT NULL REFERENCES skill(id),
  proficiency     smallint NOT NULL DEFAULT 3 CHECK (proficiency BETWEEN 1 AND 5),
  PRIMARY KEY (employee_id, skill_id)
);

-- Recurring weekly availability, used by the roster optimiser
CREATE TABLE employee_availability (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id     bigint NOT NULL REFERENCES employee(id),
  day_of_week     smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),  -- ISO: 1 = Monday
  start_local     time NOT NULL,
  end_local       time NOT NULL,
  availability    text NOT NULL DEFAULT 'available'
                  CHECK (availability IN ('available','preferred','unavailable')),
  effective_from  date NOT NULL DEFAULT current_date,
  effective_to    date,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (end_local > start_local),
  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CREATE INDEX idx_availability_employee ON employee_availability (employee_id, day_of_week);

-- Leave requests. Approved leave blocks rostering; it can later be synced
-- to Xero as a leave application.
CREATE TABLE leave_request (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id                 bigint NOT NULL REFERENCES employee(id),
  leave_type                  text NOT NULL,   -- maps to a Xero leave type, e.g. annual, personal, unpaid
  starts_at                   timestamptz NOT NULL,
  ends_at                     timestamptz NOT NULL,
  status                      text NOT NULL DEFAULT 'requested'
                              CHECK (status IN ('requested','approved','declined','cancelled')),
  decided_by_user_id          bigint REFERENCES app_user(id),
  decided_at                  timestamptz,
  notes                       text,
  xero_leave_application_id   uuid UNIQUE,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at),
  CHECK (status NOT IN ('approved','declined') OR decided_by_user_id IS NOT NULL)
);
CREATE INDEX idx_leave_employee_time ON leave_request (employee_id, starts_at);


-- =====================================================================
--  3. WORK DATA: AIRCALL CALLS, AND CHATS, EMAILS AND CLAIMS
-- =====================================================================

-- One row per integration job run, for both Aircall and Xero. Incremental
-- loads read the last successful window_to to know where to resume.
CREATE TABLE sync_run (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  integration         text NOT NULL CHECK (integration ~ '^[a-z][a-z0-9_]*$'),  -- e.g. aircall, xero, helpdesk, claims
  job                 text NOT NULL,   -- e.g. calls_backfill, calls_incremental, timesheet_export
  window_from         timestamptz,
  window_to           timestamptz,
  status              text NOT NULL DEFAULT 'running'
                      CHECK (status IN ('running','succeeded','partial','failed')),
  records_processed   integer NOT NULL DEFAULT 0,
  error_message       text,
  started_at          timestamptz NOT NULL DEFAULT now(),
  finished_at         timestamptz
);
CREATE INDEX idx_sync_run_lookup ON sync_run (integration, job, started_at DESC);

-- Raw webhook deliveries, stored before processing so nothing is lost if
-- processing fails. Processing must be idempotent (Aircall may retry).
CREATE TABLE aircall_webhook_event (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type          text NOT NULL,     -- e.g. call.ended
  resource_id         bigint,            -- the call or user the event is about
  payload             jsonb NOT NULL,
  received_at         timestamptz NOT NULL DEFAULT now(),
  processed_at        timestamptz,
  processing_error    text
);
CREATE INDEX idx_webhook_unprocessed ON aircall_webhook_event (received_at)
  WHERE processed_at IS NULL;

-- One row per Aircall call. Upserted by the API sync and by webhooks.
CREATE TABLE call_record (
  aircall_call_id     bigint PRIMARY KEY,
  direction           text NOT NULL CHECK (direction IN ('inbound','outbound')),
  aircall_number_id   bigint REFERENCES aircall_number(aircall_number_id),
  demand_stream_id    bigint REFERENCES demand_stream(id),   -- resolved from the number on load
  aircall_user_id     bigint,                                -- agent who handled it; NULL if unanswered
  employee_id         bigint REFERENCES employee(id),        -- resolved from aircall_user_id
  started_at          timestamptz NOT NULL,
  answered_at         timestamptz,
  ended_at            timestamptz,
  missed_call_reason  text,          -- as reported by Aircall (abandoned, no agent available, out of hours...)
  is_voicemail        boolean NOT NULL DEFAULT false,
  hold_seconds        integer CHECK (hold_seconds >= 0),     -- if available
  acw_seconds         integer CHECK (acw_seconds >= 0),      -- after-call work, if captured
  wait_seconds        integer GENERATED ALWAYS AS
                        (extract(epoch FROM answered_at - started_at)::integer) STORED,
  talk_seconds        integer GENERATED ALWAYS AS
                        (extract(epoch FROM ended_at - answered_at)::integer) STORED,
  interval_start      timestamptz GENERATED ALWAYS AS
                        (date_bin('15 minutes', started_at, TIMESTAMPTZ '2000-01-01 00:00:00+00')) STORED,
  raw                 jsonb NOT NULL,   -- full Aircall payload, kept so calls can be re-processed
  loaded_at           timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (answered_at IS NULL OR answered_at >= started_at),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX idx_call_stream_interval ON call_record (demand_stream_id, interval_start) WHERE direction = 'inbound';
CREATE INDEX idx_call_employee_time   ON call_record (employee_id, started_at);
CREATE INDEX idx_call_started         ON call_record (started_at);

-- Chats, emails and claim tasks from systems other than Aircall (a helpdesk
-- or chat tool, the claims platform). One row per item of work.
CREATE TABLE work_item (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_system       text NOT NULL,          -- e.g. helpdesk, claims
  external_id         text NOT NULL,          -- the item's ID in that system
  demand_stream_id    bigint NOT NULL REFERENCES demand_stream(id),
  reference           text,                   -- e.g. claim number, linking a claim's lodge, chase and complete tasks
  arrived_at          timestamptz NOT NULL,
  started_at          timestamptz,            -- first picked up by a person
  completed_at        timestamptz,
  status              text NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','in_progress','completed','abandoned','cancelled')),
  employee_id         bigint REFERENCES employee(id),
  handle_seconds      integer CHECK (handle_seconds >= 0),   -- active working time, if the system records it
  wait_seconds        integer GENERATED ALWAYS AS
                        (extract(epoch FROM started_at - arrived_at)::integer) STORED,
  interval_start      timestamptz GENERATED ALWAYS AS
                        (date_bin('15 minutes', arrived_at, TIMESTAMPTZ '2000-01-01 00:00:00+00')) STORED,
  raw                 jsonb NOT NULL,         -- full source payload, kept for re-processing
  loaded_at           timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, external_id),
  CHECK (started_at IS NULL OR started_at >= arrived_at),
  CHECK (completed_at IS NULL OR completed_at >= arrived_at),
  CHECK (status <> 'completed' OR completed_at IS NOT NULL)
);
CREATE INDEX idx_work_item_stream_interval ON work_item (demand_stream_id, interval_start);
CREATE INDEX idx_work_item_reference       ON work_item (source_system, reference);

-- Agent availability over time (available, on a call, wrap-up, away...),
-- used to compare "clocked in" against "actually taking calls".
CREATE TABLE agent_status_event (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  aircall_user_id     bigint NOT NULL,
  employee_id         bigint REFERENCES employee(id),
  status              text NOT NULL,
  started_at          timestamptz NOT NULL,
  ended_at            timestamptz,
  source_event_id     bigint REFERENCES aircall_webhook_event(id),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX idx_agent_status_employee ON agent_status_event (employee_id, started_at);

-- Calls, chats, emails and claim tasks rolled up into 15-minute intervals
-- per demand stream: the forecasting history.
CREATE TABLE interval_actual (
  demand_stream_id            bigint NOT NULL REFERENCES demand_stream(id),
  interval_start              timestamptz NOT NULL,
  offered                     integer NOT NULL DEFAULT 0,   -- arrived inside opening hours
  handled                     integer NOT NULL DEFAULT 0,   -- answered or picked up
  abandoned                   integer NOT NULL DEFAULT 0,
  short_abandoned             integer NOT NULL DEFAULT 0,   -- gone within seconds; often excluded from SL
  out_of_hours                integer NOT NULL DEFAULT 0,   -- tracked, but not staffable demand
  started_within_threshold    integer NOT NULL DEFAULT 0,   -- uses the queue's threshold at compute time
  total_handle_seconds        bigint  NOT NULL DEFAULT 0,   -- talk + hold + wrap-up (or active time), handled items only
  total_wait_seconds          bigint  NOT NULL DEFAULT 0,
  aht_seconds                 numeric(10,2) GENERATED ALWAYS AS
                                (total_handle_seconds::numeric / NULLIF(handled, 0)) STORED,
  service_level_pct           numeric(5,2) GENERATED ALWAYS AS
                                (100.0 * started_within_threshold / NULLIF(offered - short_abandoned, 0)) STORED,
  computed_at                 timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (demand_stream_id, interval_start),
  CHECK (extract(epoch FROM interval_start)::bigint % 900 = 0),     -- on a 15-minute boundary
  CHECK (handled + abandoned <= offered),
  CHECK (started_within_threshold <= handled),
  CHECK (short_abandoned <= abandoned)
);

-- Known events that distort volume: campaigns, outages, billing runs.
-- Used to clean the history and to adjust future forecasts.
CREATE TABLE calendar_event (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue_id                    bigint REFERENCES queue(id),   -- NULL = affects every queue
  name                        text NOT NULL,
  event_type                  text NOT NULL
                              CHECK (event_type IN ('campaign','outage','billing_run','holiday','other')),
  starts_at                   timestamptz NOT NULL,
  ends_at                     timestamptz NOT NULL,
  expected_volume_impact_pct  numeric(6,2),       -- e.g. +25 for a campaign
  exclude_from_history        boolean NOT NULL DEFAULT false,  -- drop from forecast training data
  notes                       text,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);


-- =====================================================================
--  4. FORECASTING
-- =====================================================================

-- How volume spreads across the week and the day. The weekday split is
-- shared by the pool; each demand stream has its own daily pattern.
CREATE TABLE arrival_profile (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staffing_pool_id    bigint NOT NULL REFERENCES staffing_pool(id),
  name                text NOT NULL,       -- e.g. 'Launch assumption v1'
  source              text NOT NULL DEFAULT 'assumed'
                      CHECK (source IN ('assumed','derived_from_history')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staffing_pool_id, name)
);

-- Share of the week's work landing on each weekday (should total 1)
CREATE TABLE arrival_profile_day (
  arrival_profile_id  bigint NOT NULL REFERENCES arrival_profile(id) ON DELETE CASCADE,
  day_of_week         smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
  share               numeric(8,6) NOT NULL CHECK (share >= 0 AND share <= 1),
  PRIMARY KEY (arrival_profile_id, day_of_week)
);

-- Share of each day's work for a stream landing in each 15-minute slot, in
-- the pool's timezone (each stream-day should total 1)
CREATE TABLE arrival_profile_slot (
  arrival_profile_id  bigint NOT NULL REFERENCES arrival_profile(id) ON DELETE CASCADE,
  demand_stream_id    bigint NOT NULL REFERENCES demand_stream(id),
  day_of_week         smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
  slot_start_local    time NOT NULL
                      CHECK (extract(minute FROM slot_start_local)::int % 15 = 0
                             AND extract(second FROM slot_start_local) = 0),
  share               numeric(8,6) NOT NULL CHECK (share >= 0 AND share <= 1),
  PRIMARY KEY (arrival_profile_id, demand_stream_id, day_of_week, slot_start_local)
);

-- A forecast for every demand stream in a pool, for one scenario.
CREATE TABLE forecast_run (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staffing_pool_id    bigint NOT NULL REFERENCES staffing_pool(id),
  -- drivers = built from business assumptions (pre-launch)
  -- history = projected from interval_actual
  -- blended = history weighted against driver assumptions while history builds up
  basis               text NOT NULL CHECK (basis IN ('drivers','history','blended')),
  scenario            text NOT NULL DEFAULT 'expected' CHECK (scenario IN ('low','expected','high')),
  method              text NOT NULL,     -- e.g. contact_rate_model, weighted_weekday_avg, holt_winters
  -- For a drivers forecast: customers, uplift, range, and each stream's
  -- monthly rate and handle time, e.g.
  --   {"active_customers": 10000, "launch_uplift_pct": 50, "scenario_multiplier": 1.0,
  --    "streams": {"Calls": {"rate_pct": 10, "aht_seconds": 420}, ...}}
  parameters          jsonb NOT NULL DEFAULT '{}',
  arrival_profile_id  bigint REFERENCES arrival_profile(id),
  history_from        timestamptz,       -- NULL for a pure drivers forecast
  history_to          timestamptz,
  horizon_from        timestamptz NOT NULL,
  horizon_to          timestamptz NOT NULL,
  status              text NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','published','superseded')),
  created_by_user_id  bigint REFERENCES app_user(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  published_at        timestamptz,
  notes               text,
  CHECK ((history_from IS NULL) = (history_to IS NULL)),
  CHECK (history_to > history_from),
  CHECK (basis = 'drivers' OR history_from IS NOT NULL),        -- history needs a window
  CHECK (basis <> 'drivers' OR arrival_profile_id IS NOT NULL), -- drivers need a spread
  CHECK (horizon_to > horizon_from),
  -- Only one published forecast (normally the expected scenario) can cover
  -- any given time for a pool
  EXCLUDE USING gist (staffing_pool_id WITH =, tstzrange(horizon_from, horizon_to) WITH &&)
    WHERE (status = 'published')
);

CREATE TABLE forecast_interval (
  forecast_run_id       bigint NOT NULL REFERENCES forecast_run(id) ON DELETE CASCADE,
  demand_stream_id      bigint NOT NULL REFERENCES demand_stream(id),
  interval_start        timestamptz NOT NULL,
  forecast_items        numeric(10,2) NOT NULL CHECK (forecast_items >= 0),
  forecast_aht_seconds  numeric(10,2) NOT NULL CHECK (forecast_aht_seconds >= 0),
  -- Planner overrides (e.g. "campaign launches Tuesday, add 20%")
  override_items        numeric(10,2) CHECK (override_items >= 0),
  override_aht_seconds  numeric(10,2) CHECK (override_aht_seconds >= 0),
  override_reason       text,
  final_items           numeric(10,2) GENERATED ALWAYS AS (COALESCE(override_items, forecast_items)) STORED,
  final_aht_seconds     numeric(10,2) GENERATED ALWAYS AS (COALESCE(override_aht_seconds, forecast_aht_seconds)) STORED,
  PRIMARY KEY (forecast_run_id, demand_stream_id, interval_start),
  CHECK (extract(epoch FROM interval_start)::bigint % 900 = 0),
  CHECK ((override_items IS NULL AND override_aht_seconds IS NULL) OR override_reason IS NOT NULL)
);


-- =====================================================================
--  5. STAFFING REQUIREMENTS (POOLED ERLANG C)
-- =====================================================================

-- Sizes the whole pool for one forecast. The pool settings and each queue's
-- service level are snapshotted, so a run can always be reproduced.
CREATE TABLE staffing_run (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  forecast_run_id           bigint NOT NULL REFERENCES forecast_run(id),
  -- pooled_priority_erlang_c: for each queue, most urgent first, size the pool
  -- for that queue plus all more urgent work, then take the largest answer
  model                     text NOT NULL DEFAULT 'pooled_priority_erlang_c'
                            CHECK (model IN ('pooled_priority_erlang_c','erlang_c','erlang_a')),
  max_occupancy_pct         numeric(5,2) NOT NULL CHECK (max_occupancy_pct > 0 AND max_occupancy_pct <= 100),
  unplanned_shrinkage_pct   numeric(5,2) NOT NULL
                            CHECK (unplanned_shrinkage_pct >= 0 AND unplanned_shrinkage_pct < 100),
  min_agents_open           integer NOT NULL CHECK (min_agents_open >= 0),
  created_by_user_id        bigint REFERENCES app_user(id),
  created_at                timestamptz NOT NULL DEFAULT now()
);

-- Each queue's target and pick-up order, as used by the run
CREATE TABLE staffing_run_queue (
  staffing_run_id           bigint NOT NULL REFERENCES staffing_run(id) ON DELETE CASCADE,
  queue_id                  bigint NOT NULL REFERENCES queue(id),
  sl_target_pct             numeric(5,2) NOT NULL CHECK (sl_target_pct > 0 AND sl_target_pct <= 100),
  sl_threshold_seconds      integer NOT NULL CHECK (sl_threshold_seconds >= 0),
  priority_rank             smallint NOT NULL CHECK (priority_rank > 0),   -- 1 = picked up first
  PRIMARY KEY (staffing_run_id, queue_id),
  UNIQUE (staffing_run_id, priority_rank)
);

-- People needed per interval for the whole pool
CREATE TABLE staffing_requirement (
  staffing_run_id           bigint NOT NULL REFERENCES staffing_run(id) ON DELETE CASCADE,
  interval_start            timestamptz NOT NULL,
  workload_erlangs          numeric(10,3) NOT NULL CHECK (workload_erlangs >= 0),   -- all queues together
  erlang_agents             integer NOT NULL CHECK (erlang_agents >= 0),            -- pooled need, before minimum cover
  required_agents           integer NOT NULL,                                       -- on the floor
  floor_applied             boolean GENERATED ALWAYS AS (required_agents > erlang_agents) STORED,
  set_by_queue_id           bigint REFERENCES queue(id),   -- whose service level sets the number; NULL = minimum cover
  separate_team_agents      integer,                        -- comparison: each queue with its own people
  required_scheduled        numeric(8,2) NOT NULL,          -- required_agents / (1 - unplanned shrinkage)
  PRIMARY KEY (staffing_run_id, interval_start),
  CHECK (extract(epoch FROM interval_start)::bigint % 900 = 0),
  CHECK (required_agents >= erlang_agents),
  CHECK (separate_team_agents IS NULL OR separate_team_agents >= required_agents),
  FOREIGN KEY (staffing_run_id, set_by_queue_id) REFERENCES staffing_run_queue (staffing_run_id, queue_id)
);

-- The same interval, broken down by queue
CREATE TABLE staffing_requirement_queue (
  staffing_run_id           bigint NOT NULL,
  interval_start            timestamptz NOT NULL,
  queue_id                  bigint NOT NULL,
  items                     numeric(10,2) NOT NULL CHECK (items >= 0),
  workload_erlangs          numeric(10,3) NOT NULL CHECK (workload_erlangs >= 0),
  expected_sl_pct           numeric(5,2),   -- at required_agents, with more urgent work served first
  separate_agents           integer CHECK (separate_agents >= 0),
  PRIMARY KEY (staffing_run_id, interval_start, queue_id),
  FOREIGN KEY (staffing_run_id, interval_start) REFERENCES staffing_requirement ON DELETE CASCADE,
  FOREIGN KEY (staffing_run_id, queue_id) REFERENCES staffing_run_queue (staffing_run_id, queue_id)
);


-- =====================================================================
--  6. ROSTERING
-- =====================================================================

CREATE TABLE shift_template (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id             bigint NOT NULL REFERENCES site(id),
  name                text NOT NULL,                 -- e.g. 'Early 7:30'
  start_local         time NOT NULL,
  duration_minutes    integer NOT NULL CHECK (duration_minutes BETWEEN 60 AND 960),  -- may cross midnight
  valid_days          smallint[] NOT NULL DEFAULT '{1,2,3,4,5}',   -- ISO weekdays it may be used on
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, name),
  CHECK (valid_days <@ '{1,2,3,4,5,6,7}'::smallint[])
);

-- Breaks are given a window, not a fixed time, so the optimiser can
-- stagger them to protect coverage.
CREATE TABLE shift_template_break (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shift_template_id         bigint NOT NULL REFERENCES shift_template(id) ON DELETE CASCADE,
  break_type                text NOT NULL CHECK (break_type IN ('rest','meal')),
  earliest_offset_minutes   integer NOT NULL CHECK (earliest_offset_minutes >= 0),  -- from shift start
  latest_offset_minutes     integer NOT NULL,
  duration_minutes          integer NOT NULL CHECK (duration_minutes > 0),
  is_paid                   boolean NOT NULL,
  CHECK (latest_offset_minutes >= earliest_offset_minutes)
);

CREATE TABLE roster_period (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id                     bigint NOT NULL REFERENCES site(id),
  start_date                  date NOT NULL,
  end_date                    date NOT NULL,
  status                      text NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','published','locked')),
  chosen_optimisation_run_id  bigint,          -- FK added below (the run references this table too)
  published_by_user_id        bigint REFERENCES app_user(id),
  published_at                timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date),
  CHECK (status = 'draft' OR published_at IS NOT NULL),
  -- Drafts can overlap (what-if versions); live rosters can't
  EXCLUDE USING gist (site_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
    WHERE (status IN ('published','locked'))
);

-- The staffing run(s) a roster was built to cover
CREATE TABLE roster_period_staffing (
  roster_period_id    bigint NOT NULL REFERENCES roster_period(id) ON DELETE CASCADE,
  staffing_run_id     bigint NOT NULL REFERENCES staffing_run(id),
  PRIMARY KEY (roster_period_id, staffing_run_id)
);

-- Each roster optimiser run: the rules it used, what it found, and whether
-- the result is proven to be the fewest paid hours possible.
CREATE TABLE roster_optimisation_run (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  roster_period_id            bigint NOT NULL REFERENCES roster_period(id) ON DELETE CASCADE,
  staffing_run_id             bigint NOT NULL REFERENCES staffing_run(id),
  solver                      text NOT NULL,     -- e.g. scip_pattern_model, heuristic_search
  parameters                  jsonb NOT NULL,    -- snapshot of work patterns, break rule and limits used
  status                      text NOT NULL DEFAULT 'running'
                              CHECK (status IN ('running','succeeded','failed')),
  proven_optimal              boolean,
  required_floor_minutes      integer CHECK (required_floor_minutes >= 0),
  rostered_floor_minutes      integer CHECK (rostered_floor_minutes >= 0),
  paid_minutes                integer CHECK (paid_minutes >= 0),
  lower_bound_paid_minutes    integer CHECK (lower_bound_paid_minutes >= 0),  -- the best any roster could do
  mix_comparison              jsonb,             -- paid minutes for each full-time / part-time mix tried
  error_message               text,
  started_at                  timestamptz NOT NULL DEFAULT now(),
  finished_at                 timestamptz,
  CHECK (status <> 'succeeded' OR (paid_minutes IS NOT NULL AND finished_at IS NOT NULL)),
  CHECK (status <> 'failed' OR error_message IS NOT NULL),
  CHECK (lower_bound_paid_minutes IS NULL OR paid_minutes IS NULL OR lower_bound_paid_minutes <= paid_minutes),
  CHECK (proven_optimal IS NOT TRUE OR lower_bound_paid_minutes = paid_minutes),
  CHECK (rostered_floor_minutes IS NULL OR required_floor_minutes IS NULL OR rostered_floor_minutes >= required_floor_minutes)
);
ALTER TABLE roster_period ADD FOREIGN KEY (chosen_optimisation_run_id) REFERENCES roster_optimisation_run(id);

-- A weekly line on the roster ("Part-time 3"), built to a work pattern.
-- The optimiser creates positions; people are assigned to them afterwards.
CREATE TABLE roster_position (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  roster_period_id      bigint NOT NULL REFERENCES roster_period(id) ON DELETE CASCADE,
  label                 text NOT NULL,
  work_pattern_id       bigint NOT NULL REFERENCES work_pattern(id),
  employee_id           bigint REFERENCES employee(id),              -- NULL until someone is assigned
  optimisation_run_id   bigint REFERENCES roster_optimisation_run(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (roster_period_id, label),
  UNIQUE (roster_period_id, employee_id)       -- one position per person per roster
);

CREATE TABLE shift (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  roster_period_id    bigint NOT NULL REFERENCES roster_period(id),
  roster_position_id  bigint REFERENCES roster_position(id),
  employee_id         bigint REFERENCES employee(id),      -- NULL = not yet filled
  shift_template_id   bigint REFERENCES shift_template(id),
  start_at            timestamptz NOT NULL,
  end_at              timestamptz NOT NULL,
  status              text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','cancelled')),
  source              text NOT NULL DEFAULT 'optimiser' CHECK (source IN ('optimiser','manual','swap')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at),
  CHECK (end_at - start_at <= interval '16 hours'),
  -- Nobody, and no roster position, can be on two overlapping shifts
  EXCLUDE USING gist (employee_id WITH =, tstzrange(start_at, end_at) WITH &&)
    WHERE (status = 'scheduled'),
  EXCLUDE USING gist (roster_position_id WITH =, tstzrange(start_at, end_at) WITH &&)
    WHERE (status = 'scheduled')
);
CREATE INDEX idx_shift_period          ON shift (roster_period_id);
CREATE INDEX idx_shift_position        ON shift (roster_position_id);
CREATE INDEX idx_shift_employee_start  ON shift (employee_id, start_at);

-- What a person does within a shift, block by block. Because the team is
-- cross-skilled, queue_work with no queue means "any queue"; naming a queue
-- ties that block to one kind of work.
CREATE TABLE shift_activity (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  shift_id        bigint NOT NULL REFERENCES shift(id) ON DELETE CASCADE,
  activity_type   text NOT NULL CHECK (activity_type IN
                    ('queue_work','rest_break','meal_break','training','meeting','coaching','offline_work')),
  queue_id        bigint REFERENCES queue(id),
  start_at        timestamptz NOT NULL,
  end_at          timestamptz NOT NULL,
  is_paid         boolean NOT NULL DEFAULT true,
  CHECK (end_at > start_at),
  CHECK (activity_type = 'queue_work' OR queue_id IS NULL),
  CHECK (activity_type <> 'meal_break' OR NOT is_paid),      -- meal breaks are unpaid
  EXCLUDE USING gist (shift_id WITH =, tstzrange(start_at, end_at) WITH &&)
);
CREATE INDEX idx_activity_time ON shift_activity (start_at) WHERE activity_type = 'queue_work';

-- Activities must sit inside their shift
CREATE FUNCTION check_activity_within_shift() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s_start timestamptz; s_end timestamptz;
BEGIN
  SELECT start_at, end_at INTO s_start, s_end FROM shift WHERE id = NEW.shift_id;
  IF NEW.start_at < s_start OR NEW.end_at > s_end THEN
    RAISE EXCEPTION 'Activity % to % falls outside shift % (% to %)',
      NEW.start_at, NEW.end_at, NEW.shift_id, s_start, s_end;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_activity_within_shift
  BEFORE INSERT OR UPDATE ON shift_activity
  FOR EACH ROW EXECUTE FUNCTION check_activity_within_shift();


-- =====================================================================
--  7. TIME & ATTENDANCE  (append-only)
-- =====================================================================

-- Every tap on the clock in/out screen. The time is set by the server,
-- never by the device, so it can't be adjusted on the phone.
CREATE TABLE clock_event (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id         bigint NOT NULL REFERENCES employee(id),
  shift_id            bigint REFERENCES shift(id),     -- rostered shift clocked against; NULL = unrostered
  event_type          text NOT NULL CHECK (event_type IN ('clock_in','break_start','break_end','clock_out')),
  event_at            timestamptz NOT NULL DEFAULT now(),
  source              text NOT NULL CHECK (source IN ('web','mobile','kiosk','manager_entry')),
  entered_by_user_id  bigint REFERENCES app_user(id),  -- the employee themselves, or the manager
  reason              text,                             -- required for manager entries
  ip_address          inet,
  user_agent          text,
  latitude            numeric(9,6),    -- only if you adopt location checks; tell staff what is collected
  longitude           numeric(9,6),
  recorded_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (source <> 'manager_entry' OR (reason IS NOT NULL AND entered_by_user_id IS NOT NULL))
);
CREATE INDEX idx_clock_employee_time ON clock_event (employee_id, event_at);

-- Corrections: void the wrong event here, then add a manager_entry with
-- the right time. The original stays on record.
CREATE TABLE clock_event_void (
  clock_event_id      bigint PRIMARY KEY REFERENCES clock_event(id),
  voided_by_user_id   bigint NOT NULL REFERENCES app_user(id),
  reason              text NOT NULL,
  voided_at           timestamptz NOT NULL DEFAULT now()
);


-- =====================================================================
--  8. TIMESHEETS & PAY CLASSIFICATION
-- =====================================================================

-- One per employee per pay period (matching their Xero payroll calendar)
CREATE TABLE timesheet (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id               bigint NOT NULL REFERENCES employee(id),
  xero_payroll_calendar_id  uuid NOT NULL REFERENCES xero_payroll_calendar(xero_payroll_calendar_id),
  period_start              date NOT NULL,
  period_end                date NOT NULL,
  status                    text NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open','submitted','approved','rejected','exported')),
  submitted_at              timestamptz,
  approved_by_user_id       bigint REFERENCES app_user(id),
  approved_at               timestamptz,
  rejection_reason          text,
  xero_timesheet_id         uuid UNIQUE,
  exported_at               timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, period_start),
  CHECK (period_end >= period_start),
  CHECK (status NOT IN ('approved','exported') OR (approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL)),
  CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL),
  CHECK (status <> 'exported' OR xero_timesheet_id IS NOT NULL)
  -- The app must also stop anyone approving their own timesheet.
);

-- One row per worked shift: rostered vs actual, reconciled from clock events.
CREATE TABLE timesheet_entry (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  timesheet_id            bigint NOT NULL REFERENCES timesheet(id),
  shift_id                bigint REFERENCES shift(id),   -- NULL = worked without a rostered shift
  work_date               date NOT NULL,                 -- local date the shift started
  -- Rostered times, copied at reconciliation so later roster edits don't rewrite history
  rostered_start_at       timestamptz,
  rostered_end_at         timestamptz,
  -- Actual times, from clock events (or manager-corrected)
  actual_start_at         timestamptz NOT NULL,
  actual_end_at           timestamptz NOT NULL,
  unpaid_break_minutes    integer NOT NULL DEFAULT 0 CHECK (unpaid_break_minutes >= 0),
  -- Exact minutes are stored. Apply any rounding policy in the pay engine,
  -- and never in a way that underpays.
  paid_minutes            integer GENERATED ALWAYS AS
                            ((extract(epoch FROM actual_end_at - actual_start_at) / 60)::integer
                             - unpaid_break_minutes) STORED,
  start_variance_minutes  integer GENERATED ALWAYS AS            -- positive = started late
                            ((extract(epoch FROM actual_start_at - rostered_start_at) / 60)::integer) STORED,
  end_variance_minutes    integer GENERATED ALWAYS AS            -- positive = finished after rostered end
                            ((extract(epoch FROM actual_end_at - rostered_end_at) / 60)::integer) STORED,
  overtime_approved       boolean NOT NULL DEFAULT false,
  manager_note            text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CHECK (actual_end_at > actual_start_at),
  CHECK ((rostered_start_at IS NULL) = (rostered_end_at IS NULL)),
  CHECK (unpaid_break_minutes < extract(epoch FROM actual_end_at - actual_start_at) / 60)
);
CREATE INDEX idx_ts_entry_timesheet ON timesheet_entry (timesheet_id);
CREATE INDEX idx_ts_entry_shift     ON timesheet_entry (shift_id);

-- The pay engine's output: minutes per pay category per day. This is
-- exactly what is sent to Xero (earnings rate + units for each day).
CREATE TABLE timesheet_line (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  timesheet_id          bigint NOT NULL REFERENCES timesheet(id),
  work_date             date NOT NULL,
  pay_category_id       bigint NOT NULL REFERENCES pay_category(id),
  minutes               integer NOT NULL CHECK (minutes > 0),
  hours                 numeric(8,4) GENERATED ALWAYS AS (minutes / 60.0) STORED,
  pay_rule_version_id   bigint NOT NULL REFERENCES pay_rule_version(id),  -- which rules produced it
  explanation           jsonb,     -- engine trace: which rule put these minutes in this category
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (timesheet_id, work_date, pay_category_id)
);

-- Once approved or exported, a timesheet's entries and lines are frozen.
-- To change them, a manager must reopen the timesheet (which is audited).
CREATE FUNCTION guard_locked_timesheet() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ts_id bigint; ts_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN ts_id := OLD.timesheet_id; ELSE ts_id := NEW.timesheet_id; END IF;
  SELECT status INTO ts_status FROM timesheet WHERE id = ts_id;
  IF ts_status IN ('approved','exported') THEN
    RAISE EXCEPTION 'Timesheet % is %. Reopen it before changing its % rows.', ts_id, ts_status, TG_TABLE_NAME;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER trg_guard_ts_entry BEFORE INSERT OR UPDATE OR DELETE ON timesheet_entry
  FOR EACH ROW EXECUTE FUNCTION guard_locked_timesheet();
CREATE TRIGGER trg_guard_ts_line BEFORE INSERT OR UPDATE OR DELETE ON timesheet_line
  FOR EACH ROW EXECUTE FUNCTION guard_locked_timesheet();


-- =====================================================================
--  9. XERO INTEGRATION
-- =====================================================================

CREATE TABLE xero_connection (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  xero_tenant_id            uuid NOT NULL UNIQUE,
  tenant_name               text,
  -- Encrypt tokens in the application (or keep them in a secrets manager).
  -- Xero refresh tokens rotate when used, so always save the newest one.
  access_token_encrypted    bytea,
  refresh_token_encrypted   bytea NOT NULL,
  access_token_expires_at   timestamptz,
  scopes                    text[] NOT NULL,
  connected_by_user_id      bigint REFERENCES app_user(id),
  connected_at              timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
  -- Aircall API credentials belong in environment variables or a secrets
  -- manager, not in this database.
);

-- Every attempt to push a timesheet to Xero, successful or not
CREATE TABLE xero_timesheet_export (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  timesheet_id        bigint NOT NULL REFERENCES timesheet(id),
  sync_run_id         bigint REFERENCES sync_run(id),
  attempted_at        timestamptz NOT NULL DEFAULT now(),
  request_payload     jsonb NOT NULL,
  http_status         integer,
  response_body       jsonb,
  succeeded           boolean NOT NULL,
  xero_timesheet_id   uuid
);
CREATE INDEX idx_xero_export_timesheet ON xero_timesheet_export (timesheet_id, attempted_at DESC);


-- =====================================================================
--  10. AUDIT LOG  (append-only)
-- =====================================================================

CREATE TABLE audit_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  app_user_id     bigint REFERENCES app_user(id),
  action          text NOT NULL,       -- e.g. timesheet.approve, timesheet.reopen, roster.publish
  entity_type     text NOT NULL,
  entity_id       text NOT NULL,
  before_data     jsonb,
  after_data      jsonb,
  ip_address      inet
);
CREATE INDEX idx_audit_entity ON audit_log (entity_type, entity_id, occurred_at);


-- =====================================================================
--  11. VIEWS
-- =====================================================================

-- Clock events that haven't been voided
CREATE VIEW v_clock_event_effective AS
SELECT ce.*
FROM clock_event ce
WHERE NOT EXISTS (SELECT 1 FROM clock_event_void v WHERE v.clock_event_id = ce.id);

-- Forecast vs actual, per demand stream and interval. Average abs_pct_error
-- over a week to get MAPE.
CREATE VIEW v_forecast_accuracy AS
SELECT fr.id                       AS forecast_run_id,
       fr.staffing_pool_id,
       fr.scenario,
       fi.demand_stream_id,
       fi.interval_start,
       fi.final_items              AS forecast_items,
       ia.offered                  AS actual_items,
       ia.offered - fi.final_items AS items_error,
       CASE WHEN ia.offered > 0
            THEN round(abs(ia.offered - fi.final_items) / ia.offered * 100, 2)
       END                         AS abs_pct_error,
       fi.final_aht_seconds        AS forecast_aht_seconds,
       ia.aht_seconds              AS actual_aht_seconds
FROM forecast_interval fi
JOIN forecast_run fr    ON fr.id = fi.forecast_run_id
JOIN interval_actual ia ON ia.demand_stream_id = fi.demand_stream_id
                       AND ia.interval_start = fi.interval_start;

-- Arrival profiles whose shares don't add up to 100%
CREATE VIEW v_arrival_profile_check AS
SELECT p.id AS arrival_profile_id, p.name, 'weekday' AS level,
       NULL::bigint AS demand_stream_id, NULL::smallint AS day_of_week,
       sum(d.share) AS total_share, abs(sum(d.share) - 1) < 0.0001 AS is_valid
FROM arrival_profile p JOIN arrival_profile_day d ON d.arrival_profile_id = p.id
GROUP BY p.id, p.name
UNION ALL
SELECT p.id, p.name, 'intraday', sl.demand_stream_id, sl.day_of_week,
       sum(sl.share), abs(sum(sl.share) - 1) < 0.0001
FROM arrival_profile p JOIN arrival_profile_slot sl ON sl.arrival_profile_id = p.id
GROUP BY p.id, p.name, sl.demand_stream_id, sl.day_of_week;

-- Rostered people on the floor vs the pool's requirement, per 15 minutes.
-- Partial overlaps count proportionally: 5 of the 15 minutes counts as 0.33.
-- Only queue_work time counts, so meal breaks and training reduce cover.
CREATE VIEW v_interval_coverage AS
SELECT rps.roster_period_id,
       fr.staffing_pool_id,
       sr.interval_start,
       sr.required_agents,
       sr.floor_applied,
       sr.set_by_queue_id,
       sr.required_scheduled,
       round(COALESCE(cov.agents, 0), 2)                        AS scheduled_agents,
       round(COALESCE(cov.agents, 0) - sr.required_agents, 2)   AS gap   -- negative = short of people
FROM roster_period_staffing rps
JOIN staffing_run st          ON st.id = rps.staffing_run_id
JOIN forecast_run fr          ON fr.id = st.forecast_run_id
JOIN staffing_requirement sr  ON sr.staffing_run_id = st.id
LEFT JOIN LATERAL (
  SELECT sum(extract(epoch FROM
               LEAST(sa.end_at, sr.interval_start + interval '15 minutes')
             - GREATEST(sa.start_at, sr.interval_start))) / 900.0 AS agents
  FROM shift s
  JOIN shift_activity sa ON sa.shift_id = s.id
  WHERE s.roster_period_id = rps.roster_period_id
    AND s.status = 'scheduled'
    AND sa.activity_type = 'queue_work'
    AND (sa.queue_id IS NULL
         OR sa.queue_id IN (SELECT q.queue_id FROM staffing_run_queue q WHERE q.staffing_run_id = st.id))
    AND sa.start_at < sr.interval_start + interval '15 minutes'
    AND sa.end_at   > sr.interval_start
) cov ON true;

-- Each roster position, week by week, checked against its work pattern:
-- weekly paid hours, days worked, one shift a day, shift lengths.
CREATE VIEW v_roster_position_check AS
WITH shift_paid AS (
  SELECT s.id, s.roster_position_id,
         (s.start_at AT TIME ZONE st.timezone)::date AS local_date,
         extract(epoch FROM s.end_at - s.start_at) / 60
           - COALESCE((SELECT sum(extract(epoch FROM a.end_at - a.start_at) / 60)
                       FROM shift_activity a WHERE a.shift_id = s.id AND NOT a.is_paid), 0) AS paid_minutes
  FROM shift s
  JOIN roster_period rp ON rp.id = s.roster_period_id
  JOIN site st          ON st.id = rp.site_id
  WHERE s.status = 'scheduled' AND s.roster_position_id IS NOT NULL
)
SELECT p.id                                     AS roster_position_id,
       p.roster_period_id,
       p.label,
       wp.name                                  AS work_pattern,
       date_trunc('week', sp.local_date)::date  AS week_starting,
       sum(sp.paid_minutes)::integer            AS paid_minutes,
       count(*)                                 AS shifts,
       count(DISTINCT sp.local_date)            AS days_worked,
       min(sp.paid_minutes)::integer            AS shortest_shift_minutes,
       max(sp.paid_minutes)::integer            AS longest_shift_minutes,
       sum(sp.paid_minutes) BETWEEN wp.weekly_min_paid_minutes AND wp.weekly_max_paid_minutes AS weekly_hours_ok,
       count(DISTINCT sp.local_date) BETWEEN wp.min_days_per_week AND wp.max_days_per_week   AS days_ok,
       count(*) = count(DISTINCT sp.local_date)                                              AS one_shift_a_day,
       min(sp.paid_minutes) >= wp.min_shift_paid_minutes
         AND max(sp.paid_minutes) <= wp.max_shift_paid_minutes                               AS shift_lengths_ok
FROM roster_position p
JOIN work_pattern wp ON wp.id = p.work_pattern_id
JOIN shift_paid sp   ON sp.roster_position_id = p.id
GROUP BY p.id, p.roster_period_id, p.label, wp.name,
         wp.weekly_min_paid_minutes, wp.weekly_max_paid_minutes, wp.min_days_per_week, wp.max_days_per_week,
         wp.min_shift_paid_minutes, wp.max_shift_paid_minutes, date_trunc('week', sp.local_date);

-- Each scheduled shift checked against the site's meal break rule: shifts
-- over the limit need one unpaid meal of the right length, with no stretch
-- of work longer than the limit before or after it.
CREATE VIEW v_shift_meal_break_check AS
SELECT s.id                       AS shift_id,
       s.roster_position_id,
       s.employee_id,
       br.meal_after_minutes,
       br.unpaid_meal_minutes,
       x.paid_minutes::integer    AS paid_minutes,
       x.meal_count,
       x.meal_minutes::integer    AS meal_minutes,
       x.minutes_before_meal::integer AS minutes_before_meal,
       x.minutes_after_meal::integer  AS minutes_after_meal,
       CASE WHEN x.paid_minutes <= br.meal_after_minutes THEN true
            ELSE x.meal_count = 1
             AND x.meal_minutes >= br.unpaid_meal_minutes
             AND x.minutes_before_meal <= br.meal_after_minutes
             AND x.minutes_after_meal  <= br.meal_after_minutes
       END                        AS meal_rule_ok
FROM shift s
JOIN roster_period rp ON rp.id = s.roster_period_id
JOIN site st          ON st.id = rp.site_id
JOIN break_rule br    ON br.site_id = rp.site_id
                     AND (s.start_at AT TIME ZONE st.timezone)::date
                         BETWEEN br.effective_from AND COALESCE(br.effective_to, 'infinity'::date)
CROSS JOIN LATERAL (
  SELECT extract(epoch FROM s.end_at - s.start_at) / 60
           - COALESCE(sum(extract(epoch FROM a.end_at - a.start_at) / 60) FILTER (WHERE NOT a.is_paid), 0) AS paid_minutes,
         count(*) FILTER (WHERE a.activity_type = 'meal_break')                                            AS meal_count,
         COALESCE(sum(extract(epoch FROM a.end_at - a.start_at) / 60) FILTER (WHERE a.activity_type = 'meal_break'), 0) AS meal_minutes,
         extract(epoch FROM min(a.start_at) FILTER (WHERE a.activity_type = 'meal_break') - s.start_at) / 60 AS minutes_before_meal,
         extract(epoch FROM s.end_at - max(a.end_at) FILTER (WHERE a.activity_type = 'meal_break')) / 60     AS minutes_after_meal
  FROM shift_activity a
  WHERE a.shift_id = s.id
) x
WHERE s.status = 'scheduled';


-- =====================================================================
--  12. TRIGGER WIRING
-- =====================================================================

-- updated_at on every table that has one
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables tb
      ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
    WHERE c.table_schema = current_schema()
      AND c.column_name = 'updated_at'
      AND tb.table_type = 'BASE TABLE'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t, t);
  END LOOP;
END $$;

-- Append-only tables
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['clock_event','clock_event_void','audit_log','xero_timesheet_export']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_append_only BEFORE UPDATE OR DELETE ON %I
         FOR EACH ROW EXECUTE FUNCTION prevent_modification()', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%s_no_truncate BEFORE TRUNCATE ON %I
         FOR EACH STATEMENT EXECUTE FUNCTION prevent_modification()', t, t);
  END LOOP;
END $$;
