import os
from collections.abc import Iterator

import psycopg
import pytest

from app.core import dbtools
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
