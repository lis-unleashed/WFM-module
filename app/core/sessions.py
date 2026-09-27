"""Sign-in sessions, whatever the sign-in method turns out to be.

The browser keeps a random token in a cookie, and app_session keeps only its
SHA-256 hash. A session works until it expires, goes unused for longer than the
idle limit, or is ended, and only while its user is active, so deactivating
someone signs them out everywhere at once.
"""

import hashlib
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

from app.core.db import Connection

Role = Literal["staff", "manager", "payroll", "admin"]  # as in app_user.role

# last_seen_at is written at most this often; the idle limit doesn't need it more precisely.
TOUCH_INTERVAL = timedelta(minutes=1)


@dataclass(frozen=True)
class NewSession:
    id: int
    token: str  # for the cookie only: it's never stored
    expires_at: datetime


@dataclass(frozen=True)
class CurrentUser:
    id: int
    email: str
    role: Role
    employee_id: int | None
    session_id: int


def hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8")).digest()


def start(
    conn: Connection,
    *,
    user_id: int,
    lifetime: timedelta,
    ip_address: str | None,
    user_agent: str | None,
) -> NewSession:
    token = secrets.token_urlsafe(32)
    row = conn.execute(
        "INSERT INTO app_session (app_user_id, token_hash, expires_at, ip_address, user_agent)"
        " VALUES (%s, %s, now() + %s, %s, %s) RETURNING id, expires_at",
        (user_id, hash_token(token), lifetime, ip_address, (user_agent or "")[:500] or None),
    ).fetchone()
    assert row is not None
    return NewSession(id=row[0], token=token, expires_at=row[1])


def authenticate(conn: Connection, token: str, *, idle_limit: timedelta) -> CurrentUser | None:
    """Whose session this is, or None if it has expired, idled out, been ended or
    belongs to someone who is no longer active."""
    row = conn.execute(
        """
        SELECT s.id, s.last_seen_at < now() - %(touch)s, u.id, u.email, u.role, u.employee_id
        FROM app_session s
        JOIN app_user u ON u.id = s.app_user_id
        WHERE s.token_hash = %(hash)s
          AND s.revoked_at IS NULL
          AND s.expires_at > now()
          AND s.last_seen_at > now() - %(idle)s
          AND u.is_active
        """,
        {"hash": hash_token(token), "idle": idle_limit, "touch": TOUCH_INTERVAL},
    ).fetchone()
    if row is None:
        return None
    session_id, stale, user_id, email, role, employee_id = row
    if stale:
        conn.execute("UPDATE app_session SET last_seen_at = now() WHERE id = %s", (session_id,))
    return CurrentUser(user_id, email, role, employee_id, session_id)


def end(conn: Connection, session_id: int, *, reason: Literal["logout", "revoked"]) -> None:
    conn.execute(
        "UPDATE app_session SET revoked_at = now(), revoked_reason = %s"
        " WHERE id = %s AND revoked_at IS NULL",
        (reason, session_id),
    )
