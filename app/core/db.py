"""The app's database connection pool."""

from typing import Any

import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg_pool import ConnectionPool

Connection = psycopg.Connection[Any]


def app_conninfo(conninfo: str) -> str:
    """The connection details the app uses, with its session settings added.

    Every connection works in UTC, so a local time always has to be worked out
    explicitly with the staffing pool's or the site's timezone.
    """
    options = conninfo_to_dict(conninfo).get("options") or ""
    return make_conninfo(
        conninfo, options=f"{options} -c timezone=UTC".strip(), application_name="wfm-api"
    )


def create_pool(conninfo: str, *, max_size: int = 10) -> ConnectionPool[Connection]:
    """Connections are in autocommit mode: code that changes data wraps the change
    (and its audit entry) in `with conn.transaction():`, so the commit happens there."""
    return ConnectionPool(
        app_conninfo(conninfo),
        min_size=1,
        max_size=max_size,
        kwargs={"autocommit": True},
        open=False,
        name="wfm-api",
    )
