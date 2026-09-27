-- =====================================================================
--  0002 — database role for the application
--
--  The app connects as a login that is a member of wfm_app, never as the
--  schema owner. wfm_app can read and write ordinary tables, but on the
--  append-only tables (the ones guarded by prevent_modification) it can
--  only read and insert. The append-only rule is enforced by permissions
--  as well as by the trigger.
--
--  Logins and passwords are set up per environment (see the README), never
--  in a migration. A migration that adds tables or views must end with:
--      SELECT grant_app_privileges();
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wfm_app') THEN
    CREATE ROLE wfm_app NOLOGIN;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE EXCEPTION 'role wfm_app does not exist, and % is not allowed to create it', current_user
    USING HINT = 'Ask a database administrator to run: CREATE ROLE wfm_app NOLOGIN;';
END $$;

-- Gives wfm_app what it needs on every table and view in the schema. Safe to
-- run again, which is how later migrations cover the tables they add. The
-- append-only tables are found from their trigger, so a new one is covered
-- without anyone having to remember to list it.
CREATE FUNCTION grant_app_privileges() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  r record;
BEGIN
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO wfm_app', current_schema());
  FOR r IN
    SELECT c.relname,
           c.relkind IN ('v', 'm') AS is_view,
           EXISTS (SELECT FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                   WHERE t.tgrelid = c.oid AND p.proname = 'prevent_modification') AS append_only
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = current_schema()
      AND c.relkind IN ('r', 'p', 'v', 'm')
  LOOP
    IF r.is_view OR r.relname = 'schema_migrations' THEN
      -- Views are read-only, and schema_migrations belongs to the migration runner
      EXECUTE format('GRANT SELECT ON %I TO wfm_app', r.relname);
    ELSIF r.append_only THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON %I FROM wfm_app', r.relname);
      EXECUTE format('GRANT SELECT, INSERT ON %I TO wfm_app', r.relname);
    ELSE
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO wfm_app', r.relname);
    END IF;
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION grant_app_privileges() FROM PUBLIC;

SELECT grant_app_privileges();
