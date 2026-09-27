#!/bin/bash
# Gets a Claude Code on the web session ready for `make check`: starts the
# container's PostgreSQL 16 and installs the Python dependencies. Does nothing
# anywhere else; on a laptop, `make check` starts PostgreSQL with Docker.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

# PostgreSQL 16 is installed but not running when the session starts. Start it,
# and give the postgres superuser the local-only password that the default
# WFM_ADMIN_DATABASE_URL expects (see app/core/settings.py).
if command -v pg_ctlcluster >/dev/null && pg_lsclusters --no-header | grep -q '^16 \+main '; then
  if ! pg_lsclusters --no-header | grep -q '^16 \+main \+[0-9]\+ \+online'; then
    pg_ctlcluster 16 main start
  fi
  su postgres -c "psql -qAtc \"ALTER USER postgres PASSWORD 'postgres'\"" >/dev/null
else
  echo "session-start: PostgreSQL 16 isn't installed here, so the database tests won't run." >&2
fi

# Python 3.12 and every dependency, exactly as locked.
uv sync --locked
