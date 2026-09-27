-- =====================================================================
--  0003 — sign-in sessions
--
--  One row per signed-in browser or phone. The cookie holds a random
--  token and only its SHA-256 hash is stored here, so a copy of the
--  database can't be used to sign in as anyone. A session ends when it
--  expires, sits idle for too long (the app checks this, because it
--  knows the idle limit) or is revoked. The row is kept as a record.
--
--  Sessions don't depend on how people sign in, which is still to be
--  decided (handover section 9).
-- =====================================================================

CREATE TABLE app_session (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  app_user_id     bigint NOT NULL REFERENCES app_user(id),
  token_hash      bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),  -- SHA-256 of the cookie token
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,     -- the absolute limit, however active the session is
  revoked_at      timestamptz,
  -- logout = the person signed out; revoked = ended by someone else, or because access was removed
  revoked_reason  text CHECK (revoked_reason IN ('logout','revoked')),
  ip_address      inet,
  user_agent      text,
  CHECK (expires_at > created_at),
  CHECK (last_seen_at >= created_at),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at),
  CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);
CREATE INDEX idx_app_session_user ON app_session (app_user_id) WHERE revoked_at IS NULL;

SELECT grant_app_privileges();
