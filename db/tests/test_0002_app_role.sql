-- =====================================================================
--  0002 — the app's database role
--  wfm_app can do the app's everyday work, but can never change or delete
--  rows in an append-only table, whatever happens to the trigger.
-- =====================================================================
SET client_min_messages = notice;

-- Runs a statement as wfm_app and expects "permission denied"
CREATE FUNCTION pg_temp.expect_denied(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    SET LOCAL ROLE wfm_app;
    EXECUTE stmt;
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'PASS: %', label;
      RETURN;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'FAIL: % (wrong error %: %)', label, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL: % (statement was accepted)', label;
END $$;

-- Runs a statement as wfm_app, expects it to work, then undoes it
CREATE FUNCTION pg_temp.expect_allowed(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    SET LOCAL ROLE wfm_app;
    EXECUTE stmt;
    RAISE EXCEPTION USING ERRCODE = 'WFM00';  -- roll back whatever it did
  EXCEPTION
    WHEN SQLSTATE 'WFM00' THEN
      RAISE NOTICE 'PASS: %', label;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'FAIL: % (%: %)', label, SQLSTATE, SQLERRM;
  END;
END $$;

CREATE FUNCTION pg_temp.check(label text, ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok THEN
    RAISE NOTICE 'PASS: %', label;
  ELSE
    RAISE EXCEPTION 'FAIL: %', label;
  END IF;
END $$;

CREATE VIEW pg_temp.append_only_tables AS
SELECT DISTINCT c.oid, c.relname
FROM pg_class c
JOIN pg_trigger t ON t.tgrelid = c.oid
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE p.proname = 'prevent_modification';

-- -------------------------------------------------- append-only tables
SELECT pg_temp.check('the append-only tables are found from their trigger (update this list when adding one)',
  (SELECT array_agg(relname::text ORDER BY relname) FROM pg_temp.append_only_tables)
    = array['audit_log', 'clock_event', 'clock_event_void', 'xero_timesheet_export']);

SELECT pg_temp.expect_denied('the app cannot change clock events', $$UPDATE clock_event SET event_at = now()$$);
SELECT pg_temp.expect_denied('the app cannot delete clock events', $$DELETE FROM clock_event$$);
SELECT pg_temp.expect_denied('the app cannot truncate clock events', $$TRUNCATE clock_event$$);
SELECT pg_temp.expect_denied('the app cannot change voids', $$UPDATE clock_event_void SET reason = 'changed'$$);
SELECT pg_temp.expect_denied('the app cannot delete voids', $$DELETE FROM clock_event_void$$);
SELECT pg_temp.expect_denied('the app cannot truncate voids', $$TRUNCATE clock_event_void$$);
SELECT pg_temp.expect_denied('the app cannot change the audit log', $$UPDATE audit_log SET action = 'changed'$$);
SELECT pg_temp.expect_denied('the app cannot delete from the audit log', $$DELETE FROM audit_log$$);
SELECT pg_temp.expect_denied('the app cannot truncate the audit log', $$TRUNCATE audit_log$$);
SELECT pg_temp.expect_denied('the app cannot change Xero export attempts', $$UPDATE xero_timesheet_export SET succeeded = true$$);
SELECT pg_temp.expect_denied('the app cannot delete Xero export attempts', $$DELETE FROM xero_timesheet_export$$);
SELECT pg_temp.expect_denied('the app cannot truncate Xero export attempts', $$TRUNCATE xero_timesheet_export$$);

SELECT pg_temp.check('no append-only table can be changed, deleted or truncated by the app',
  NOT EXISTS (SELECT FROM pg_temp.append_only_tables a
              WHERE has_table_privilege('wfm_app', a.oid, 'UPDATE')
                 OR has_table_privilege('wfm_app', a.oid, 'DELETE')
                 OR has_table_privilege('wfm_app', a.oid, 'TRUNCATE')));
SELECT pg_temp.check('the app can read and add to every append-only table',
  NOT EXISTS (SELECT FROM pg_temp.append_only_tables a
              WHERE NOT has_table_privilege('wfm_app', a.oid, 'SELECT')
                 OR NOT has_table_privilege('wfm_app', a.oid, 'INSERT')));
SELECT pg_temp.expect_allowed('the app can write to the audit log',
  $$INSERT INTO audit_log (action, entity_type, entity_id) VALUES ('test.probe', 'site', '1')$$);

-- ---------------------------------------------------- everyday work
SELECT pg_temp.expect_allowed('the app can add ordinary rows', $$INSERT INTO skill (name) VALUES ('Probe')$$);
SELECT pg_temp.expect_allowed('the app can change ordinary rows', $$UPDATE skill SET description = 'changed'$$);
SELECT pg_temp.expect_allowed('the app can remove ordinary rows', $$DELETE FROM skill$$);
SELECT pg_temp.expect_allowed('the app can read the rule-check views',
  $$SELECT (SELECT count(*) FROM v_roster_position_check) + (SELECT count(*) FROM v_shift_meal_break_check)
         + (SELECT count(*) FROM v_interval_coverage)$$);
SELECT pg_temp.expect_allowed('the app can list open intervals', $$SELECT count(*) FROM open_intervals(1, '2026-09-21', '2026-09-27')$$);
SELECT pg_temp.expect_allowed('the app can see which migrations are applied', $$SELECT count(*) FROM schema_migrations$$);

-- ---------------------------------------------------- off limits
SELECT pg_temp.expect_denied('the app cannot rewrite the migration history', $$DELETE FROM schema_migrations$$);
SELECT pg_temp.expect_denied('the app cannot empty ordinary tables', $$TRUNCATE skill CASCADE$$);
SELECT pg_temp.expect_denied('the app cannot create tables', $$CREATE TABLE app_made (id int)$$);
SELECT pg_temp.expect_denied('the app cannot change the schema', $$ALTER TABLE skill ADD COLUMN app_made int$$);
SELECT pg_temp.expect_denied('the app cannot hand out privileges', $$SELECT grant_app_privileges()$$);
SELECT pg_temp.check('wfm_app has no login of its own and no special powers',
  (SELECT NOT (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls) FROM pg_roles WHERE rolname = 'wfm_app'));
