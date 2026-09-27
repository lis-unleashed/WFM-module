import re
import secrets
from collections.abc import Iterator

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app.core import dbtools, migrations
from app.core.dbtools import ServerError


@pytest.fixture
def names(admin_url: str) -> Iterator[dict[str, str]]:
    """Unique login and database names, removed again afterwards."""
    suffix = secrets.token_hex(3)
    n = {
        "db": f"wfm_setup_{suffix}",
        "owner": f"wfm_t_owner_{suffix}",
        "app": f"wfm_t_api_{suffix}",
    }
    yield n
    with psycopg.connect(admin_url, autocommit=True) as conn:
        conn.execute(
            sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(n["db"]))
        )
        for role in (n["app"], n["owner"]):
            conn.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role)))


def login(admin_url: str, user: str, password: str, db: str) -> str:
    return make_conninfo(admin_url, user=user, password=password, dbname=db)


def test_creates_the_logins_and_database_and_the_app_login_is_restricted(admin_url, names):
    owner_url = login(admin_url, names["owner"], "owner-pw", names["db"])
    app_url = login(admin_url, names["app"], "app-pw", names["db"])
    assert dbtools.setup_local_database(admin_url, owner_url, app_url) == [
        f"created login {names['owner']}",
        f"created login {names['app']} (a member of wfm_app)",
        f"created database {names['db']}",
    ]
    migrations.migrate(owner_url)
    with psycopg.connect(app_url) as conn:
        assert conn.execute("SELECT count(*) FROM site").fetchone() == (0,)
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("DELETE FROM audit_log")
    with psycopg.connect(admin_url) as conn:
        row = conn.execute(
            "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = %s", (names["db"],)
        ).fetchone()
    assert row == (names["owner"],)


def test_running_it_again_only_resets_the_passwords(admin_url, names):
    owner_url = login(admin_url, names["owner"], "owner-pw", names["db"])
    app_url = login(admin_url, names["app"], "app-pw", names["db"])
    dbtools.setup_local_database(admin_url, owner_url, app_url)
    assert dbtools.setup_local_database(admin_url, owner_url, app_url) == [
        f"updated login {names['owner']}",
        f"updated login {names['app']} (a member of wfm_app)",
        f"database {names['db']} already exists",
    ]


def test_a_superuser_is_never_changed(admin_url, names):
    admin_user = str(conninfo_to_dict(admin_url)["user"])
    owner_url = login(admin_url, admin_user, "not-the-real-password", names["db"])
    app_url = login(admin_url, names["app"], "app-pw", names["db"])
    done = dbtools.setup_local_database(admin_url, owner_url, app_url)
    assert done[0] == f"{admin_user} is a superuser, so it was left alone"
    psycopg.connect(admin_url).close()  # the admin password still works


def test_the_app_login_cannot_be_a_superuser(admin_url, names):
    admin_user = str(conninfo_to_dict(admin_url)["user"])
    owner_url = login(admin_url, names["owner"], "owner-pw", names["db"])
    app_url = login(admin_url, admin_user, "x", names["db"])
    with pytest.raises(ServerError, match="must not be a superuser"):
        dbtools.setup_local_database(admin_url, owner_url, app_url)


def test_the_app_and_migrations_need_different_logins(admin_url, names):
    same = login(admin_url, names["owner"], "pw", names["db"])
    with pytest.raises(ServerError, match="need different database logins"):
        dbtools.setup_local_database(admin_url, same, same)


def test_both_urls_must_name_the_same_database(admin_url, names):
    owner_url = login(admin_url, names["owner"], "pw", names["db"])
    app_url = login(admin_url, names["app"], "pw", names["db"] + "_other")
    with pytest.raises(ServerError, match="must name the same database"):
        dbtools.setup_local_database(admin_url, owner_url, app_url)


def test_each_url_needs_a_password(admin_url, names):
    owner_url = make_conninfo(admin_url, user=names["owner"], password="", dbname=names["db"])
    app_url = login(admin_url, names["app"], "pw", names["db"])
    with pytest.raises(ServerError, match=re.escape("needs a user name and a password")):
        dbtools.setup_local_database(admin_url, owner_url, app_url)


def test_describe_leaves_out_the_password():
    described = dbtools.describe("postgresql://someone:s3cret@db.example.com:6543/wfm")
    assert described == "someone@db.example.com:6543/wfm"
