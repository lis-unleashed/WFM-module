-- =====================================================================
--  WFM schema v0.3 — tests
--  Builds a realistic week end to end and tries to break every rule.
--  Each "expect failure" block passes only if the database rejects it.
-- =====================================================================
SET client_min_messages = notice;
SET TIME ZONE 'Australia/Adelaide';

-- Helper: run a statement that must fail with a given error class
CREATE FUNCTION pg_temp.expect_fail(label text, stmt text, want text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  RAISE EXCEPTION 'FAIL: % (statement was accepted)', label;
EXCEPTION
  WHEN check_violation OR exclusion_violation OR unique_violation OR foreign_key_violation OR not_null_violation OR raise_exception THEN
    IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
    IF want <> 'any' AND SQLSTATE <> want THEN RAISE EXCEPTION 'FAIL: % (wrong error %: %)', label, SQLSTATE, SQLERRM; END IF;
    RAISE NOTICE 'PASS: %', label;
END $$;
-- SQLSTATEs: 23514 check, 23P01 exclusion, 23505 unique, 23503 foreign key, P0001 raised by trigger

-- ---------------------------------------------------------------- setup
INSERT INTO site (name, timezone, state_code) VALUES ('Contact centre', 'Australia/Adelaide', 'SA');
INSERT INTO skill (name) VALUES ('All work');
INSERT INTO staffing_pool (site_id, name) VALUES (1, 'Cross-skilled team');
INSERT INTO queue (staffing_pool_id, name, skill_id, sl_target_pct, sl_threshold_seconds) VALUES
  (1, 'Calls and chats', 1, 80, 20), (1, 'Emails', 1, 80, 14400),
  (1, 'Urgent claims',   1, 90, 600), (1, 'Routine claims', 1, 80, 86400);
INSERT INTO demand_stream (queue_id, channel, task, name, concurrency)
SELECT q.id, v.channel, v.task, v.name, v.conc FROM queue q JOIN (VALUES
  ('Calls and chats', 'voice', 'contact',    'Calls', 1.0), ('Calls and chats', 'chat', 'contact', 'Chats', 2.0),
  ('Emails',          'email', 'contact',    'Emails', 1.0),
  ('Urgent claims',   'claim', 'end_to_end', 'Urgent claims', 1.0),
  ('Routine claims',  'claim', 'lodge',      'Lodge', 1.0), ('Routine claims', 'claim', 'chase', 'Chase', 1.0),
  ('Routine claims',  'claim', 'complete',   'Complete', 1.0)) v(qname, channel, task, name, conc) ON v.qname = q.name;
SELECT 'streams per queue' AS test, q.name, count(*) FROM queue q JOIN demand_stream ds ON ds.queue_id = q.id GROUP BY q.id, q.name ORDER BY q.id;

SELECT pg_temp.expect_fail('only chats can be handled several at once',
  $$INSERT INTO demand_stream (queue_id, channel, task, name, concurrency) VALUES (2, 'email', 'contact', 'Two emails at once', 2)$$, '23514');
SELECT pg_temp.expect_fail('claims must be a lodge, chase, complete or end-to-end task',
  $$INSERT INTO demand_stream (queue_id, channel, task, name) VALUES (4, 'claim', 'contact', 'Claim contact')$$, '23514');
SELECT pg_temp.expect_fail('a site must have its timezone set deliberately',
  $$INSERT INTO site (name, state_code) VALUES ('No timezone', 'SA')$$, '23502');

-- ------------------------------------------------------- opening hours
INSERT INTO opening_hours (staffing_pool_id, day_of_week, opens_local, closes_local, effective_from)
SELECT 1, d, time '09:00', time '21:00', date '2026-09-01' FROM generate_series(1,5) d
UNION ALL SELECT 1, d, time '10:00', time '15:00', date '2026-09-01' FROM generate_series(6,7) d;
SELECT 'open intervals in a week (expect 280)' AS test, count(*) FROM open_intervals(1, '2026-09-21', '2026-09-27');
SELECT 'Sydney 9am opening, Adelaide staff clock (expect 08:30)' AS test,
       (min(interval_start) AT TIME ZONE 'Australia/Adelaide')::time FROM open_intervals(1, '2026-09-21', '2026-09-21');
SELECT 'Sydney daylight saving starts Sun 4 Oct (10am moves an hour earlier in UTC)' AS test, local_date, min(interval_start) AT TIME ZONE 'UTC' AS utc
FROM open_intervals(1, '2026-10-03', '2026-10-04') GROUP BY local_date ORDER BY local_date;
INSERT INTO opening_hours_exception (staffing_pool_id, exception_date, is_closed, reason) VALUES (1, '2026-10-05', true, 'Public holiday (example)');
SELECT 'closed exception day (expect 0 slots)' AS test, count(*) FROM open_intervals(1, '2026-10-05', '2026-10-05');

-- --------------------------------------------- work patterns & contracts
INSERT INTO work_pattern (name, employment_type, weekly_min_paid_minutes, weekly_max_paid_minutes, min_days_per_week, max_days_per_week, min_shift_paid_minutes, max_shift_paid_minutes) VALUES
  ('Full-time 37.5',  'full_time', 2250, 2250, 5, 5, 450, 450),
  ('Part-time 20',    'part_time', 1200, 1200, 3, 4, 300, 450),
  ('Casual',          'casual',       0, 1500, 0, 5, 180, 450);
SELECT pg_temp.expect_fail('work pattern rules must add up (4 days x 6 hrs is more than 20 hrs)',
  $$INSERT INTO work_pattern (name, employment_type, weekly_min_paid_minutes, weekly_max_paid_minutes, min_days_per_week, max_days_per_week, min_shift_paid_minutes, max_shift_paid_minutes)
    VALUES ('Impossible', 'part_time', 1200, 1200, 4, 5, 360, 450)$$, '23514');
SELECT pg_temp.expect_fail('shift lengths must be in quarter hours',
  $$INSERT INTO work_pattern (name, employment_type, weekly_min_paid_minutes, weekly_max_paid_minutes, min_days_per_week, max_days_per_week, min_shift_paid_minutes, max_shift_paid_minutes)
    VALUES ('Odd', 'part_time', 1200, 1200, 3, 4, 301, 450)$$, '23514');
INSERT INTO break_rule (site_id, effective_from, unpaid_meal_minutes, meal_after_minutes) VALUES (1, '2026-01-01', 30, 300);

INSERT INTO xero_payroll_calendar VALUES ('11111111-1111-1111-1111-111111111111', 'Weekly', 'WEEKLY', '2026-09-21', NULL);
INSERT INTO pay_rule_set (name, instrument) VALUES ('Agents', 'Award or agreement to confirm');
INSERT INTO pay_rule_version (pay_rule_set_id, version, effective_from, rules) VALUES (1, 1, '2026-07-01', '{"ordinary_span": ["07:00", "19:00"]}');
INSERT INTO pay_category (code, name) VALUES ('ORD', 'Ordinary hours');
INSERT INTO team (site_id, name) VALUES (1, 'Team A');
INSERT INTO employee (site_id, team_id, first_name, last_name, email, start_date, aircall_user_id, xero_payroll_calendar_id) VALUES
  (1, 1, 'Fran', 'Fulltime', 'fran@example.com', '2026-09-01', 9001, '11111111-1111-1111-1111-111111111111'),
  (1, 1, 'Pat',  'Parttime', 'pat@example.com',  '2026-09-01', 9002, '11111111-1111-1111-1111-111111111111');
INSERT INTO app_user (employee_id, email, role) VALUES (1, 'fran@example.com', 'staff'), (2, 'pat@example.com', 'staff');
INSERT INTO app_user (email, role) VALUES ('manager@example.com', 'manager');
INSERT INTO employee_contract (employee_id, effective_from, employment_type, pay_rule_set_id, work_pattern_id) VALUES
  (1, '2026-09-01', 'full_time', 1, 1), (2, '2026-09-01', 'part_time', 1, 2);
SELECT pg_temp.expect_fail('part-timers need a work pattern',
  $$INSERT INTO employee_contract (employee_id, effective_from, employment_type, pay_rule_set_id) VALUES (2, '2027-01-01', 'part_time', 1)$$, '23514');
SELECT pg_temp.expect_fail('contracts for one person cannot overlap',
  $$INSERT INTO employee_contract (employee_id, effective_from, employment_type, pay_rule_set_id, work_pattern_id) VALUES (1, '2026-10-01', 'full_time', 1, 1)$$, '23P01');

-- --------------------------------------------------------- work data
INSERT INTO aircall_number VALUES (555, 'Main line', '+61 8 0000 0000', (SELECT id FROM demand_stream WHERE name = 'Calls'), now());
INSERT INTO call_record (aircall_call_id, direction, aircall_number_id, demand_stream_id, started_at, answered_at, ended_at, raw)
VALUES (1, 'inbound', 555, (SELECT id FROM demand_stream WHERE name = 'Calls'), '2026-09-21 08:37:30', '2026-09-21 08:37:45', '2026-09-21 08:44:45', '{}');
SELECT 'call lands in the 8:30 Adelaide interval (9:00 Sydney)' AS test, interval_start, wait_seconds, talk_seconds FROM call_record;

INSERT INTO work_item (source_system, external_id, demand_stream_id, reference, arrived_at, started_at, completed_at, status, raw) VALUES
  ('helpdesk', 'chat-1', (SELECT id FROM demand_stream WHERE name = 'Chats'), 'conv-88', '2026-09-21 08:40', '2026-09-21 08:40:30', '2026-09-21 08:52', 'completed', '{}'),
  ('claims', 'CLM-100-lodge', (SELECT id FROM demand_stream WHERE name = 'Lodge'), 'CLM-100', '2026-09-21 09:02', NULL, NULL, 'open', '{}'),
  ('claims', 'CLM-100-chase', (SELECT id FROM demand_stream WHERE name = 'Chase'), 'CLM-100', '2026-09-22 10:00', NULL, NULL, 'open', '{}');
SELECT 'claim tasks linked by reference' AS test, reference, count(*) FROM work_item WHERE source_system = 'claims' GROUP BY reference;
SELECT pg_temp.expect_fail('the same item cannot be loaded twice',
  $$INSERT INTO work_item (source_system, external_id, demand_stream_id, arrived_at, raw) VALUES ('helpdesk', 'chat-1', 2, now(), '{}')$$, '23505');
SELECT pg_temp.expect_fail('completed work needs a completion time',
  $$INSERT INTO work_item (source_system, external_id, demand_stream_id, arrived_at, status, raw) VALUES ('helpdesk', 'chat-2', 2, now(), 'completed', '{}')$$, '23514');

INSERT INTO interval_actual (demand_stream_id, interval_start, offered, handled, started_within_threshold, total_handle_seconds)
VALUES ((SELECT id FROM demand_stream WHERE name = 'Calls'), '2026-09-21 08:30', 10, 9, 8, 3780);
SELECT 'stream actuals' AS test, aht_seconds, service_level_pct FROM interval_actual;
SELECT pg_temp.expect_fail('actuals must sit on 15-minute boundaries',
  $$INSERT INTO interval_actual (demand_stream_id, interval_start) VALUES (1, '2026-09-21 08:37')$$, '23514');

-- ---------------------------------------------------------- forecasting
INSERT INTO arrival_profile (staffing_pool_id, name) VALUES (1, 'Launch assumption v1');
INSERT INTO arrival_profile_day VALUES (1,1,0.19),(1,2,0.18),(1,3,0.17),(1,4,0.16),(1,5,0.15),(1,6,0.08),(1,7,0.07);
INSERT INTO arrival_profile_slot (arrival_profile_id, demand_stream_id, day_of_week, slot_start_local, share)
SELECT 1, ds.id, 1, (time '09:00' + g * interval '15 minutes')::time, 1.0 / 48 FROM demand_stream ds CROSS JOIN generate_series(0, 47) g WHERE ds.name = 'Calls';
SELECT 'profile check' AS test, level, demand_stream_id IS NOT NULL AS per_stream, round(total_share, 4) AS total, is_valid FROM v_arrival_profile_check ORDER BY level;

INSERT INTO forecast_run (staffing_pool_id, basis, scenario, method, arrival_profile_id, horizon_from, horizon_to, status, parameters)
VALUES (1, 'drivers', 'expected', 'contact_rate_model', 1, '2026-09-21', '2026-09-28', 'published', '{"active_customers": 10000}');
INSERT INTO forecast_interval (forecast_run_id, demand_stream_id, interval_start, forecast_items, forecast_aht_seconds)
SELECT 1, ds.id, oi.interval_start, CASE ds.name WHEN 'Calls' THEN 1.5 WHEN 'Chats' THEN 0.6 ELSE 0.3 END, 420
FROM demand_stream ds CROSS JOIN open_intervals(1, '2026-09-21', '2026-09-21') oi;
SELECT 'forecast intervals for Monday (7 streams x 48)' AS test, count(*) FROM forecast_interval;
SELECT 'forecast vs actual' AS test, forecast_items, actual_items, abs_pct_error FROM v_forecast_accuracy;
SELECT pg_temp.expect_fail('history forecasts need a history window',
  $$INSERT INTO forecast_run (staffing_pool_id, basis, method, horizon_from, horizon_to) VALUES (1, 'history', 'holt_winters', '2026-11-02', '2026-11-09')$$, '23514');
SELECT pg_temp.expect_fail('only one published forecast can cover a time',
  $$INSERT INTO forecast_run (staffing_pool_id, basis, method, arrival_profile_id, horizon_from, horizon_to, status) VALUES (1, 'drivers', 'contact_rate_model', 1, '2026-09-25', '2026-10-02', 'published')$$, '23P01');

-- --------------------------------------------------- pooled staffing run
INSERT INTO staffing_run (forecast_run_id, max_occupancy_pct, unplanned_shrinkage_pct, min_agents_open) VALUES (1, 85, 10, 2);
INSERT INTO staffing_run_queue (staffing_run_id, queue_id, sl_target_pct, sl_threshold_seconds, priority_rank)
SELECT 1, id, sl_target_pct, sl_threshold_seconds, rank() OVER (ORDER BY sl_threshold_seconds) FROM queue;
SELECT 'pick-up order' AS test, q.name, r.priority_rank FROM staffing_run_queue r JOIN queue q ON q.id = r.queue_id ORDER BY r.priority_rank;
SELECT pg_temp.expect_fail('two queues cannot share a priority',
  $$UPDATE staffing_run_queue SET priority_rank = 1 WHERE queue_id = 2$$, '23505');

-- Monday: 2 on the floor all day (minimum cover), 3 from 10am to 1pm where calls and chats need it
INSERT INTO staffing_requirement (staffing_run_id, interval_start, workload_erlangs, erlang_agents, required_agents, set_by_queue_id, separate_team_agents, required_scheduled)
SELECT 1, oi.interval_start,
       CASE WHEN oi.local_time >= '10:00' AND oi.local_time < '13:00' THEN 1.6 ELSE 0.9 END,
       CASE WHEN oi.local_time >= '10:00' AND oi.local_time < '13:00' THEN 3 ELSE 2 END,
       CASE WHEN oi.local_time >= '10:00' AND oi.local_time < '13:00' THEN 3 ELSE 2 END,
       CASE WHEN oi.local_time >= '10:00' AND oi.local_time < '13:00' THEN 1 END,
       5, CASE WHEN oi.local_time >= '10:00' AND oi.local_time < '13:00' THEN 3.33 ELSE 2.22 END
FROM open_intervals(1, '2026-09-21', '2026-09-21') oi;
INSERT INTO staffing_requirement_queue (staffing_run_id, interval_start, queue_id, items, workload_erlangs, expected_sl_pct, separate_agents)
SELECT 1, sr.interval_start, q.id, 1, 0.25, 95, 1 FROM staffing_requirement sr CROSS JOIN queue q;
SELECT 'pooled requirement' AS test, count(*) AS intervals, sum(required_agents) / 4.0 AS floor_hours,
       count(*) FILTER (WHERE set_by_queue_id IS NULL) AS at_minimum_cover FROM staffing_requirement;
SELECT pg_temp.expect_fail('the pool can never need fewer than Erlang C says',
  $$INSERT INTO staffing_requirement (staffing_run_id, interval_start, workload_erlangs, erlang_agents, required_agents, required_scheduled) VALUES (1, '2026-09-22 09:00+10', 1, 3, 2, 2.2)$$, '23514');
SELECT pg_temp.expect_fail('a pooled team is never bigger than separate teams',
  $$INSERT INTO staffing_requirement (staffing_run_id, interval_start, workload_erlangs, erlang_agents, required_agents, separate_team_agents, required_scheduled) VALUES (1, '2026-09-22 09:00+10', 1, 3, 3, 2, 3.3)$$, '23514');
SELECT pg_temp.expect_fail('"set by" must be a queue in this run',
  $$UPDATE staffing_requirement SET set_by_queue_id = 999 WHERE interval_start = '2026-09-21 10:00+10'$$, '23503');

-- -------------------------------------- roster optimiser run & positions
INSERT INTO roster_period (site_id, start_date, end_date) VALUES (1, '2026-09-21', '2026-09-27');
INSERT INTO roster_period_staffing VALUES (1, 1);
SELECT pg_temp.expect_fail('"proven optimal" needs the lower bound to equal the result',
  $$INSERT INTO roster_optimisation_run (roster_period_id, staffing_run_id, solver, parameters, status, proven_optimal, paid_minutes, lower_bound_paid_minutes, finished_at)
    VALUES (1, 1, 'scip_pattern_model', '{}', 'succeeded', true, 11850, 11700, now())$$, '23514');
INSERT INTO roster_optimisation_run (roster_period_id, staffing_run_id, solver, parameters, status, proven_optimal,
       required_floor_minutes, rostered_floor_minutes, paid_minutes, lower_bound_paid_minutes, mix_comparison, finished_at)
VALUES (1, 1, 'scip_pattern_model', '{"work_patterns": ["Full-time 37.5", "Part-time 20"], "break_rule": {"meal": 30, "after": 300}}',
        'succeeded', true, 10725, 11850, 11850, 11850, '[{"full_time": 1, "part_time": 8, "paid_minutes": 11850}]', now());
UPDATE roster_period SET chosen_optimisation_run_id = (SELECT max(id) FROM roster_optimisation_run) WHERE id = 1;
INSERT INTO roster_position (roster_period_id, label, work_pattern_id, employee_id, optimisation_run_id)
SELECT 1, v.label, v.wp, v.emp, (SELECT max(id) FROM roster_optimisation_run)
FROM (VALUES ('Full-time 1', 1, 1), ('Part-time 1', 2, 2), ('Part-time 2', 2, NULL::bigint)) v(label, wp, emp);

-- Full-time 1: 9am-5pm Sydney (8:30-4:30 Adelaide) Mon-Fri, 7.5 paid hours, 30-min meal at 12:30 Sydney
INSERT INTO shift (roster_period_id, roster_position_id, employee_id, start_at, end_at)
SELECT 1, 1, 1, d + time '08:30', d + time '16:30' FROM generate_series(date '2026-09-21', date '2026-09-25', interval '1 day') d;
INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at, is_paid)
SELECT s.id, v.t, v.a, v.b, v.t <> 'meal_break' FROM shift s CROSS JOIN LATERAL (VALUES
  ('queue_work', s.start_at, s.start_at + interval '3.5 hours'),
  ('meal_break', s.start_at + interval '3.5 hours', s.start_at + interval '4 hours'),
  ('queue_work', s.start_at + interval '4 hours', s.end_at)) v(t, a, b) WHERE s.roster_position_id = 1;
-- Part-time 1: four 5-hour shifts, no meal needed
INSERT INTO shift (roster_period_id, roster_position_id, employee_id, start_at, end_at) VALUES
  (1, 2, 2, '2026-09-21 08:30', '2026-09-21 13:30'), (1, 2, 2, '2026-09-22 08:30', '2026-09-22 13:30'),
  (1, 2, 2, '2026-09-24 15:30', '2026-09-24 20:30'), (1, 2, 2, '2026-09-26 09:30', '2026-09-26 14:30');
INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at) SELECT id, 'queue_work', start_at, end_at FROM shift WHERE roster_position_id = 2;
-- Part-time 2 (not yet assigned): three days, 6 + 7 + 7 paid hours, deliberately missing a meal on the 7-hour Wednesday
INSERT INTO shift (roster_period_id, roster_position_id, start_at, end_at) VALUES
  (1, 3, '2026-09-21 09:30', '2026-09-21 16:00'), (1, 3, '2026-09-23 12:30', '2026-09-23 19:30'), (1, 3, '2026-09-25 12:30', '2026-09-25 20:00');
INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at, is_paid)
SELECT s.id, v.t, v.a, v.b, v.t <> 'meal_break' FROM shift s CROSS JOIN LATERAL (VALUES
  ('queue_work', s.start_at, s.start_at + interval '3 hours'),
  ('meal_break', s.start_at + interval '3 hours', s.start_at + interval '3.5 hours'),
  ('queue_work', s.start_at + interval '3.5 hours', s.end_at)) v(t, a, b)
WHERE s.roster_position_id = 3 AND s.start_at::date <> '2026-09-23';
INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at) SELECT id, 'queue_work', start_at, end_at FROM shift WHERE roster_position_id = 3 AND start_at::date = '2026-09-23';

SELECT 'position rule check' AS test, label, paid_minutes / 60.0 AS paid_hours, days_worked, weekly_hours_ok, days_ok, one_shift_a_day, shift_lengths_ok
FROM v_roster_position_check ORDER BY label;
SELECT 'meal breaks (Part-time 2 Wednesday should fail)' AS test, rp.label, (s.start_at AT TIME ZONE 'Australia/Sydney')::date AS day, m.paid_minutes, m.meal_count, m.meal_rule_ok
FROM v_shift_meal_break_check m JOIN shift s ON s.id = m.shift_id JOIN roster_position rp ON rp.id = s.roster_position_id
WHERE NOT m.meal_rule_ok OR rp.label = 'Full-time 1' AND s.start_at::date = '2026-09-21' ORDER BY 2, 3;
SELECT 'Monday cover vs requirement (Sydney time)' AS test, (interval_start AT TIME ZONE 'Australia/Sydney')::time AS t, required_agents, scheduled_agents, gap
FROM v_interval_coverage WHERE interval_start AT TIME ZONE 'Australia/Sydney' IN ('2026-09-21 09:00', '2026-09-21 12:30', '2026-09-21 13:15', '2026-09-21 16:30') ORDER BY 2;

SELECT pg_temp.expect_fail('a position cannot have overlapping shifts',
  $$INSERT INTO shift (roster_period_id, roster_position_id, start_at, end_at) VALUES (1, 3, '2026-09-21 15:00', '2026-09-21 18:00')$$, '23P01');
SELECT pg_temp.expect_fail('meal breaks are unpaid',
  $$INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at, is_paid) SELECT id, 'meal_break', start_at, start_at + interval '30 minutes', true FROM shift WHERE roster_position_id = 2 LIMIT 1$$, '23514');
SELECT pg_temp.expect_fail('activities must sit inside their shift',
  $$INSERT INTO shift_activity (shift_id, activity_type, start_at, end_at) SELECT id, 'training', end_at, end_at + interval '30 minutes' FROM shift WHERE roster_position_id = 1 LIMIT 1$$, 'P0001');
SELECT pg_temp.expect_fail('one position per person per roster',
  $$INSERT INTO roster_position (roster_period_id, label, work_pattern_id, employee_id) VALUES (1, 'Part-time 9', 2, 2)$$, '23505');

-- ------------------------------------ time & attendance (from v0.2, unchanged)
INSERT INTO clock_event (employee_id, shift_id, event_type, event_at, source, entered_by_user_id)
SELECT 1, id, 'clock_in', start_at + interval '2 minutes', 'web', 1 FROM shift WHERE roster_position_id = 1 ORDER BY start_at LIMIT 1;
INSERT INTO clock_event (employee_id, shift_id, event_type, event_at, source, entered_by_user_id)
SELECT 1, id, 'clock_out', end_at + interval '4 minutes', 'web', 1 FROM shift WHERE roster_position_id = 1 ORDER BY start_at LIMIT 1;
SELECT pg_temp.expect_fail('clock events cannot be edited', $$UPDATE clock_event SET event_at = event_at - interval '10 minutes'$$, 'P0001');
SELECT pg_temp.expect_fail('clock events cannot be deleted', $$DELETE FROM clock_event$$, 'P0001');
INSERT INTO timesheet (employee_id, xero_payroll_calendar_id, period_start, period_end) VALUES (1, '11111111-1111-1111-1111-111111111111', '2026-09-21', '2026-09-27');
INSERT INTO timesheet_entry (timesheet_id, shift_id, work_date, rostered_start_at, rostered_end_at, actual_start_at, actual_end_at, unpaid_break_minutes)
SELECT 1, s.id, '2026-09-21', s.start_at, s.end_at, s.start_at + interval '2 minutes', s.end_at + interval '4 minutes', 30
FROM shift s WHERE roster_position_id = 1 ORDER BY start_at LIMIT 1;
SELECT 'rostered vs actual' AS test, paid_minutes, start_variance_minutes, end_variance_minutes FROM timesheet_entry;
UPDATE timesheet SET status = 'approved', approved_by_user_id = 3, approved_at = now() WHERE id = 1;
SELECT pg_temp.expect_fail('approved timesheets are frozen', $$UPDATE timesheet_entry SET unpaid_break_minutes = 0$$, 'P0001');
SELECT pg_temp.expect_fail('export to Xero needs a Xero timesheet ID', $$UPDATE timesheet SET status = 'exported' WHERE id = 1$$, '23514');

-- ------------------------------------------------------------- plumbing
UPDATE queue SET sl_target_pct = 85 WHERE name = 'Emails';
SELECT 'updated_at bumps on edit' AS test, updated_at > created_at AS ok FROM queue WHERE name = 'Emails';
INSERT INTO sync_run (integration, job) VALUES ('helpdesk', 'chats_incremental');
SELECT pg_temp.expect_fail('integration names are simple identifiers', $$INSERT INTO sync_run (integration, job) VALUES ('Help Desk!', 'x')$$, '23514');
