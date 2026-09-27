import re
import secrets
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from uuid import UUID

import psycopg
import pytest
from pydantic import BaseModel

from app.core import audit
from app.core.audit import AuditError


def add_site(conn: psycopg.Connection, name: str) -> int:
    row = conn.execute(
        "INSERT INTO site (name, timezone, state_code) VALUES (%s, 'Australia/Sydney', 'NSW')"
        " RETURNING id",
        (name,),
    ).fetchone()
    assert row is not None
    return int(row[0])


def entries_for(conn: psycopg.Connection, entity_id: int) -> list[tuple[object, ...]]:
    return conn.execute(
        "SELECT action, entity_type, app_user_id, before_data, after_data, host(ip_address)"
        " FROM audit_log WHERE entity_type = 'site' AND entity_id = %s",
        (str(entity_id),),
    ).fetchall()


def test_the_entry_is_committed_with_the_change(app_conn, make_user):
    manager = make_user("manager")
    name = f"Site {secrets.token_hex(3)}"
    with app_conn.transaction():
        site_id = add_site(app_conn, name)
        audit.record(
            app_conn,
            action="site.create",
            entity_type="site",
            entity_id=site_id,
            actor_user_id=manager,
            after={"name": name, "timezone": "Australia/Sydney"},
            ip_address="203.0.113.7",
        )
    assert entries_for(app_conn, site_id) == [
        ("site.create", "site", manager, None, {"name": name, "timezone": "Australia/Sydney"},
         "203.0.113.7"),
    ]  # fmt: skip


def test_the_entry_is_rolled_back_with_the_change(app_conn):
    name = f"Site {secrets.token_hex(3)}"
    with pytest.raises(RuntimeError), app_conn.transaction():
        site_id = add_site(app_conn, name)
        audit.record(
            app_conn, action="site.create", entity_type="site", entity_id=site_id,
            actor_user_id=None, after={"name": name},
        )  # fmt: skip
        raise RuntimeError("the change failed after the audit entry was written")
    assert app_conn.execute("SELECT count(*) FROM site WHERE name = %s", (name,)).fetchone() == (0,)
    assert entries_for(app_conn, site_id) == []


def test_it_refuses_to_write_outside_a_transaction(app_conn):
    with pytest.raises(AuditError, match="inside the transaction that makes the change"):
        audit.record(
            app_conn, action="site.create", entity_type="site", entity_id=1, actor_user_id=None
        )


@pytest.mark.parametrize("action", ["approve", "Timesheet.approve", "timesheet.", "time sheet.x"])
def test_action_names_look_like_thing_dot_verb(app_conn, action):
    with (
        pytest.raises(AuditError, match=re.escape("look like 'timesheet.approve'")),
        app_conn.transaction(),
    ):
        audit.record(
            app_conn, action=action, entity_type="timesheet", entity_id=1, actor_user_id=None
        )


def test_ip_addresses_are_checked(app_conn):
    with (
        pytest.raises(ValueError, match="does not appear to be an IPv4 or IPv6 address"),
        app_conn.transaction(),
    ):
        audit.record(
            app_conn, action="auth.login", entity_type="app_session", entity_id=1,
            actor_user_id=None, ip_address="testclient",
        )  # fmt: skip


def test_secrets_are_redacted_at_any_depth():
    snap = audit.snapshot(
        {
            "email": "pat@example.com",
            "password_hash": "$argon2id$...",
            "xero": {
                "refresh_token_encrypted": b"\x00\x01",
                "scopes": ["payroll.timesheets"],
                "history": [{"access_token": "abc", "tenant": "Unleashed"}],
            },
        }
    )
    assert snap == {
        "email": "pat@example.com",
        "password_hash": "[redacted]",
        "xero": {
            "refresh_token_encrypted": "[redacted]",
            "scopes": ["payroll.timesheets"],
            "history": [{"access_token": "[redacted]", "tenant": "Unleashed"}],
        },
    }


class Approval(BaseModel):
    timesheet_id: int
    approved_at: datetime


@dataclass
class Shift:
    paid_minutes: int
    length: timedelta


def test_snapshots_are_plain_json_with_exact_values():
    snap = audit.snapshot(
        {
            "work_date": date(2026, 9, 21),
            "rate": Decimal("32.0600"),
            "xero_employee_id": UUID("11111111-1111-1111-1111-111111111111"),
            "approval": Approval(
                timesheet_id=7, approved_at=datetime(2026, 9, 28, 1, 30, tzinfo=UTC)
            ),
            "shift": Shift(paid_minutes=450, length=timedelta(hours=8)),
        }
    )
    assert snap == {
        "work_date": "2026-09-21",
        "rate": "32.0600",  # a string, so no rounding
        "xero_employee_id": "11111111-1111-1111-1111-111111111111",
        "approval": {"timesheet_id": 7, "approved_at": "2026-09-28T01:30:00Z"},
        "shift": {"paid_minutes": 450, "length": "PT8H"},
    }
