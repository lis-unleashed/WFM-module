"""Writes to audit_log: who did what to which record, with before and after snapshots.

record() runs inside the transaction that makes the change, so the audit entry
is committed or rolled back with it. There is never a change without its entry,
or an entry for a change that didn't happen. audit_log is append-only (see
0001 and 0002), so entries can't be edited afterwards.
"""

import ipaddress
import re
from typing import Any

import psycopg
from psycopg.pq import TransactionStatus
from psycopg.types.json import Jsonb
from pydantic_core import to_jsonable_python

# e.g. timesheet.approve, timesheet.reopen, roster.publish, auth.login
ACTION = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")
# The kind of record, usually its table: timesheet, roster_period, app_session
ENTITY_TYPE = re.compile(r"^[a-z][a-z0-9_]*$")
# Values under keys like these never reach the audit log, at any depth.
SECRET_KEY = re.compile(r"password|secret|token|api_key|encrypted", re.IGNORECASE)
REDACTED = "[redacted]"


class AuditError(Exception):
    """record() was called in a way that would give an unreliable audit trail."""


def record(
    conn: psycopg.Connection[Any],
    *,
    action: str,
    entity_type: str,
    entity_id: str | int,
    actor_user_id: int | None,
    before: Any = None,
    after: Any = None,
    ip_address: str | None = None,
) -> int:
    """Adds an audit entry in the current transaction and returns its id.

    `before` and `after` can be dicts, Pydantic models or dataclasses. Dates,
    decimals and the like are stored as JSON strings, and anything under a
    secret-looking key (password, token, secret...) is replaced by "[redacted]".
    """
    if conn.info.transaction_status == TransactionStatus.IDLE:
        raise AuditError(
            "audit.record() must be called inside the transaction that makes the change "
            "(with conn.transaction(): ...)"
        )
    if not ACTION.match(action):
        raise AuditError(f"audit actions look like 'timesheet.approve', not {action!r}")
    if not ENTITY_TYPE.match(entity_type):
        raise AuditError(f"entity types look like 'timesheet', not {entity_type!r}")
    ip = str(ipaddress.ip_address(ip_address)) if ip_address is not None else None
    row = conn.execute(
        "INSERT INTO audit_log"
        " (app_user_id, action, entity_type, entity_id, before_data, after_data, ip_address)"
        " VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
        (actor_user_id, action, entity_type, str(entity_id), _jsonb(before), _jsonb(after), ip),
    ).fetchone()
    if row is None:
        raise AuditError("the audit entry wasn't written")
    return int(row[0])


def snapshot(value: Any) -> Any:
    """A JSON-ready copy of a record for the audit log, with secrets redacted."""
    return _redact(to_jsonable_python(value, bytes_mode="base64"))


def _jsonb(value: Any) -> Jsonb | None:
    return None if value is None else Jsonb(snapshot(value))


def _redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: REDACTED if SECRET_KEY.search(str(key)) else _redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact(item) for item in value]
    return value
