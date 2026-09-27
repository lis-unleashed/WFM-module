-- =====================================================================
--  0003 — sign-in sessions
-- =====================================================================
SET client_min_messages = notice;

-- As in test_schema.sql: run a statement that must fail with a given error class
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

-- As in test_0002_app_role.sql: run a statement as wfm_app, expect it to work, then undo it
CREATE FUNCTION pg_temp.expect_allowed(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    SET LOCAL ROLE wfm_app;
    EXECUTE stmt;
    RAISE EXCEPTION USING ERRCODE = 'WFM00';
  EXCEPTION
    WHEN SQLSTATE 'WFM00' THEN
      RAISE NOTICE 'PASS: %', label;
    WHEN OTHERS THEN
      RAISE EXCEPTION 'FAIL: % (%: %)', label, SQLSTATE, SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO app_user (email, role) VALUES ('pat@example.com', 'staff');
INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (1, sha256('token-1'), now() + interval '12 hours');

-- --------------------------------------------------------------- rules
SELECT pg_temp.expect_fail('only a SHA-256 hash of the token is stored',
  $$INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (1, 'token-2'::bytea, now() + interval '1 hour')$$, '23514');
SELECT pg_temp.expect_fail('a token can belong to only one session',
  $$INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (1, sha256('token-1'), now() + interval '1 hour')$$, '23505');
SELECT pg_temp.expect_fail('a session belongs to a real user',
  $$INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (999, sha256('token-3'), now() + interval '1 hour')$$, '23503');
SELECT pg_temp.expect_fail('a session must expire after it starts',
  $$INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (1, sha256('token-4'), now() - interval '1 minute')$$, '23514');
SELECT pg_temp.expect_fail('a session can''t be used before it started',
  $$UPDATE app_session SET last_seen_at = created_at - interval '1 second'$$, '23514');
SELECT pg_temp.expect_fail('ending a session needs a reason',
  $$UPDATE app_session SET revoked_at = now()$$, '23514');
SELECT pg_temp.expect_fail('a reason needs the time the session ended',
  $$UPDATE app_session SET revoked_reason = 'logout'$$, '23514');
SELECT pg_temp.expect_fail('only known reasons for ending a session',
  $$UPDATE app_session SET revoked_at = now(), revoked_reason = 'bored'$$, '23514');

-- ------------------------------------------------------- the app's role
SELECT pg_temp.expect_allowed('the app can start sessions',
  $$INSERT INTO app_session (app_user_id, token_hash, expires_at) VALUES (1, sha256('token-5'), now() + interval '1 hour')$$);
SELECT pg_temp.expect_allowed('the app can record activity on a session', $$UPDATE app_session SET last_seen_at = now()$$);
SELECT pg_temp.expect_allowed('the app can end sessions', $$UPDATE app_session SET revoked_at = now(), revoked_reason = 'logout'$$);
