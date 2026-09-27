"""Creating and inspecting databases, for local tooling and tests only.

Roles are cluster-wide in PostgreSQL, so these helpers only ever create the
two group roles below, and never give them a login or a password.
"""

import secrets
import shutil
import subprocess
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any

import psycopg
from psycopg import pq, sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app.core.paths import COMPOSE_FILE

OWNER_ROLE = "wfm_owner"  # owns the schema; migrations run as this role
APP_ROLE = "wfm_app"  # what the app may do (see 0002_app_role.sql)


class ServerError(Exception):
    """PostgreSQL isn't running and couldn't be started."""


def with_database(conninfo: str, dbname: str) -> str:
    """The same connection details, pointed at another database."""
    return make_conninfo(conninfo, dbname=dbname)


def describe(conninfo: str) -> str:
    """user@host:port/dbname without the password, for messages."""
    p = conninfo_to_dict(conninfo)
    host = p.get("host", "localhost")
    return f"{p.get('user', '?')}@{host}:{p.get('port', 5432)}/{p.get('dbname', '?')}"


def is_running(conninfo: str) -> bool:
    """True if a server is accepting connections there. Doesn't check the login."""
    target = make_conninfo(conninfo, connect_timeout=3)
    return pq.Ping(pq.PGconn.ping(target.encode())) == pq.Ping.OK


def ensure_server(
    admin_url: str, *, on_start: Callable[[], None] | None = None, wait_seconds: float = 60
) -> None:
    """Makes sure PostgreSQL is running, starting the Docker Compose one if nothing is.

    Also checks the login works, so a wrong password isn't mistaken for a
    server that isn't there.
    """
    where = describe(admin_url)
    if not is_running(admin_url):
        if shutil.which("docker") is None:
            raise ServerError(
                f"PostgreSQL isn't running at {where}. Start PostgreSQL 16, install Docker "
                "so this command can start one, or point WFM_ADMIN_DATABASE_URL at a server."
            )
        if on_start is not None:
            on_start()
        try:
            subprocess.run(
                ["docker", "compose", "-f", str(COMPOSE_FILE), "up", "--detach", "--wait", "db"],
                check=True,
            )
        except subprocess.CalledProcessError as e:
            raise ServerError("Docker Compose couldn't start PostgreSQL (see above).") from e
        deadline = time.monotonic() + wait_seconds
        while not is_running(admin_url):
            if time.monotonic() > deadline:
                raise ServerError(f"PostgreSQL started but isn't accepting connections at {where}.")
            time.sleep(1)
    try:
        psycopg.connect(admin_url, connect_timeout=5).close()
    except psycopg.OperationalError as e:
        raise ServerError(f"PostgreSQL is running at {where} but the login failed: {e}") from e


def ensure_role(conn: psycopg.Connection[Any], name: str) -> None:
    """Creates a role with no login, unless it already exists."""
    if conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (name,)).fetchone() is None:
        conn.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(name)))


def ensure_group_roles(admin_url: str) -> None:
    with psycopg.connect(admin_url, autocommit=True) as conn:
        ensure_role(conn, OWNER_ROLE)
        ensure_role(conn, APP_ROLE)


def setup_local_database(admin_url: str, migration_url: str, app_url: str) -> list[str]:
    """Creates the logins and database that the two URLs describe. Returns what it did.

    For local and test use: it sets the logins' passwords to the ones in the
    URLs. It never touches a superuser, and it refuses to let the app log in
    as the schema owner, because the owner can change anything.
    """
    owner = conninfo_to_dict(migration_url)
    app = conninfo_to_dict(app_url)
    dbname = owner.get("dbname")
    if not dbname or app.get("dbname") != dbname:
        raise ServerError(
            "WFM_DATABASE_URL and WFM_MIGRATION_DATABASE_URL must name the same database."
        )
    if owner.get("user") == app.get("user"):
        raise ServerError(
            "The app and migrations need different database logins, so the app "
            "can't change the schema or the append-only tables."
        )
    done: list[str] = []
    with psycopg.connect(admin_url, autocommit=True) as conn:
        ensure_role(conn, APP_ROLE)
        done += _ensure_login(conn, owner)
        done += _ensure_login(conn, app, member_of=APP_ROLE)
        if conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)).fetchone():
            done.append(f"database {dbname} already exists")
        else:
            conn.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(str(dbname)), sql.Identifier(str(owner["user"]))
                )
            )
            done.append(f"created database {dbname}")
    return done


def _ensure_login(
    conn: psycopg.Connection[Any], params: dict[str, Any], *, member_of: str | None = None
) -> list[str]:
    user, password = params.get("user"), params.get("password")
    if not user or not password:
        raise ServerError("Each database URL needs a user name and a password.")
    row = conn.execute("SELECT rolsuper FROM pg_roles WHERE rolname = %s", (user,)).fetchone()
    if row is not None and row[0]:
        if member_of is not None:
            raise ServerError(f"The app's login ({user}) must not be a superuser.")
        return [f"{user} is a superuser, so it was left alone"]
    statement = (
        "ALTER ROLE {} LOGIN PASSWORD {}" if row is not None else "CREATE ROLE {} LOGIN PASSWORD {}"
    )
    conn.execute(sql.SQL(statement).format(sql.Identifier(user), sql.Literal(password)))
    done = [f"{'updated' if row is not None else 'created'} login {user}"]
    if member_of is not None:
        conn.execute(
            sql.SQL("GRANT {} TO {}").format(sql.Identifier(member_of), sql.Identifier(user))
        )
        done[0] += f" (a member of {member_of})"
    return done


def create_database(admin_url: str, dbname: str, *, owner: str) -> None:
    with psycopg.connect(admin_url, autocommit=True) as conn:
        conn.execute(
            sql.SQL("CREATE DATABASE {} OWNER {}").format(
                sql.Identifier(dbname), sql.Identifier(owner)
            )
        )


def drop_database(admin_url: str, dbname: str) -> None:
    with psycopg.connect(admin_url, autocommit=True) as conn:
        conn.execute(
            sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(dbname))
        )


@contextmanager
def scratch_database(admin_url: str, prefix: str, *, owner: str = OWNER_ROLE) -> Iterator[str]:
    """A brand-new, empty database that is dropped afterwards. Yields its name."""
    dbname = f"{prefix}_{secrets.token_hex(4)}"
    create_database(admin_url, dbname, owner=owner)
    try:
        yield dbname
    finally:
        drop_database(admin_url, dbname)
