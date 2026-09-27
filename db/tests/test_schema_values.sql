-- =====================================================================
--  WFM schema — time rules
--  test_schema.sql prints these values for a person to read; this file
--  checks them, so a change that breaks the time rules turns CI red.
--  Timestamps are compared in UTC; local times are always converted
--  explicitly with the pool's or the site's timezone.
-- =====================================================================
SET client_min_messages = notice;
SET TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.expect_equal(label text, got anycompatible, want anycompatible) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF got IS NOT DISTINCT FROM want THEN
    RAISE NOTICE 'PASS: %', label;
  ELSE
    RAISE EXCEPTION 'FAIL: % (got %, expected %)', label, got, want;
  END IF;
END $$;

-- ---------------------------------------------------------------- setup
-- As in test_schema.sql: staff in Adelaide, opening hours in Sydney time.
INSERT INTO site (name, timezone, state_code) VALUES ('Contact centre', 'Australia/Adelaide', 'SA');
INSERT INTO skill (name) VALUES ('All work');
INSERT INTO staffing_pool (site_id, name) VALUES (1, 'Cross-skilled team');
INSERT INTO queue (staffing_pool_id, name, skill_id, sl_target_pct, sl_threshold_seconds) VALUES (1, 'Calls and chats', 1, 80, 20);
INSERT INTO demand_stream (queue_id, channel, task, name) VALUES (1, 'voice', 'contact', 'Calls');
INSERT INTO opening_hours (staffing_pool_id, day_of_week, opens_local, closes_local, effective_from)
SELECT 1, d, time '09:00', time '21:00', date '2026-09-01' FROM generate_series(1,5) d
UNION ALL SELECT 1, d, time '10:00', time '15:00', date '2026-09-01' FROM generate_series(6,7) d;
INSERT INTO opening_hours_exception (staffing_pool_id, exception_date, is_closed, reason) VALUES (1, '2026-10-05', true, 'Public holiday (example)');

-- ------------------------------------------------------- opening hours
SELECT pg_temp.expect_equal('a week has 280 open 15-minute intervals',
  (SELECT count(*) FROM open_intervals(1, '2026-09-21', '2026-09-27')), 280);
SELECT pg_temp.expect_equal('a weekday is open 9am to 9pm Sydney time (48 intervals)',
  (SELECT count(*) FROM open_intervals(1, '2026-09-21', '2026-09-21')), 48);
SELECT pg_temp.expect_equal('a weekend day is open 10am to 3pm Sydney time (20 intervals)',
  (SELECT count(*) FROM open_intervals(1, '2026-09-26', '2026-09-26')), 20);
SELECT pg_temp.expect_equal('a 9am Sydney opening is 8:30am on an Adelaide clock',
  (SELECT (min(interval_start) AT TIME ZONE 'Australia/Adelaide')::time FROM open_intervals(1, '2026-09-21', '2026-09-21')), time '08:30');
SELECT pg_temp.expect_equal('before daylight saving, the 10am Saturday opening is midnight UTC',
  (SELECT min(interval_start) FROM open_intervals(1, '2026-10-03', '2026-10-03')), timestamptz '2026-10-03 00:00+00');
SELECT pg_temp.expect_equal('once daylight saving starts on Sunday 4 October, 10am is an hour earlier in UTC',
  (SELECT min(interval_start) FROM open_intervals(1, '2026-10-04', '2026-10-04')), timestamptz '2026-10-03 23:00+00');
SELECT pg_temp.expect_equal('a closed day has no open intervals',
  (SELECT count(*) FROM open_intervals(1, '2026-10-05', '2026-10-05')), 0);

-- --------------------------------------------------------------- calls
-- 8:37:30am in Adelaide (UTC+9:30 until 4 October), answered after 15 seconds, 7 minutes' talk
INSERT INTO call_record (aircall_call_id, direction, demand_stream_id, started_at, answered_at, ended_at, raw)
VALUES (1, 'inbound', 1, '2026-09-21 08:37:30+09:30', '2026-09-21 08:37:45+09:30', '2026-09-21 08:44:45+09:30', '{}');
SELECT pg_temp.expect_equal('a call counts in the 15-minute interval it started in (8:30am Adelaide)',
  (SELECT interval_start FROM call_record WHERE aircall_call_id = 1), timestamptz '2026-09-21 08:30+09:30');
SELECT pg_temp.expect_equal('wait and talk seconds come from the call''s timestamps',
  (SELECT array[wait_seconds, talk_seconds] FROM call_record WHERE aircall_call_id = 1), array[15, 420]);

-- ------------------------------------------------------------ plumbing
INSERT INTO queue (staffing_pool_id, name, created_at, updated_at) VALUES (1, 'Emails', '2026-01-01', '2026-01-01');
UPDATE queue SET sl_target_pct = 85 WHERE name = 'Emails';
SELECT pg_temp.expect_equal('an edit moves updated_at forward and leaves created_at alone',
  (SELECT updated_at > timestamptz '2026-01-02' AND created_at = timestamptz '2026-01-01' FROM queue WHERE name = 'Emails'), true);
