import os
import secrets
from collections.abc import Callable, Iterator
from typing import Any

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from app.core import dbtools, migrations
from app.core.settings import LOCAL_ADMIN_DATABASE_URL


@pytest.fixture(scope="session")
def admin_url() -> str:
    """A superuser login on the test server: WFM_ADMIN_DATABASE_URL, or the local default."""
    url = os.environ.get("WFM_ADMIN_DATABASE_URL", LOCAL_ADMIN_DATABASE_URL)
    try:
        psycopg.connect(url, connect_timeout=5).close()
    except psycopg.OperationalError as e:
        pytest.fail(
            f"Can't reach PostgreSQL at {dbtools.describe(url)} ({e}). "
            "Run `uv run wfm db ensure-server` first.",
            pytrace=False,
        )
    dbtools.ensure_group_roles(url)
    return url


@pytest.fixture
def empty_db(admin_url: str) -> Iterator[str]:
    """Connection details for a brand-new, empty database owned by wfm_owner."""
    with dbtools.scratch_database(admin_url, "wfm_pytest") as dbname:
        yield dbtools.with_database(admin_url, dbname)


@pytest.fixture(scope="session")
def migrated_db(admin_url: str) -> Iterator[str]:
    """A superuser login on a database migrated to the latest schema, shared by the tests.

    Tests share it, so they create their own rows (unique emails and so on)
    and never rely on a table being empty.
    """
    with dbtools.scratch_database(admin_url, "wfm_pytest") as dbname:
        url = dbtools.with_database(admin_url, dbname)
        migrations.migrate(url, role=dbtools.OWNER_ROLE)
        yield url


@pytest.fixture(scope="session")
def app_db_url(migrated_db: str) -> str:
    """The migrated database with only the app's privileges, as the app has in production."""
    return make_conninfo(migrated_db, options=f"-c role={dbtools.APP_ROLE}")


@pytest.fixture
def app_conn(app_db_url: str) -> Iterator[psycopg.Connection[Any]]:
    with psycopg.connect(app_db_url, autocommit=True) as conn:
        yield conn


@pytest.fixture
def make_user(migrated_db: str) -> Callable[..., int]:
    """Creates an app_user and returns its id."""

    def make(role: str = "staff", *, active: bool = True, email: str | None = None) -> int:
        email = email or f"user-{secrets.token_hex(4)}@example.com"
        with psycopg.connect(migrated_db, autocommit=True) as conn:
            row = conn.execute(
                "INSERT INTO app_user (email, role, is_active) VALUES (%s, %s, %s) RETURNING id",
                (email, role, active),
            ).fetchone()
        assert row is not None
        return int(row[0])

    return make
