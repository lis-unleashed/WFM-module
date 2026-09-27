import secrets
from collections.abc import Callable, Iterator
from typing import Annotated, Any

import psycopg
import pytest
from fastapi import Depends
from fastapi.testclient import TestClient
from httpx2 import Response

from app.api.deps import require_role
from app.core.sessions import CurrentUser, hash_token
from app.core.settings import Settings
from app.main import create_app

BASE = "https://testserver"
FROM_APP = {"Origin": BASE}
COOKIE = "__Host-wfm_session"


def settings_for(database_url: str, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "env": "test",
        "database_url": database_url,
        "allowed_origins": BASE,
        **overrides,
    }
    return Settings(**values)


@pytest.fixture
def client(app_db_url: str) -> Iterator[TestClient]:
    app = create_app(settings_for(app_db_url))

    @app.get("/test/managers-only")
    def managers_only(
        user: Annotated[CurrentUser, Depends(require_role("manager", "admin"))],
    ) -> dict[str, int]:
        return {"id": user.id}

    with TestClient(app, base_url=BASE) as c:
        yield c


@pytest.fixture
def user(make_user: Callable[..., int], migrated_db: str) -> dict[str, Any]:
    email = f"pat-{secrets.token_hex(3)}@example.com"
    return {"id": make_user("staff", email=email), "email": email}


def sign_in(client: TestClient, email: str) -> Response:
    return client.post("/auth/dev-login", json={"email": email}, headers=FROM_APP)


def session_row(migrated_db: str, token: str) -> tuple[Any, ...] | None:
    with psycopg.connect(migrated_db) as conn:
        return conn.execute(
            "SELECT id, app_user_id, revoked_reason FROM app_session WHERE token_hash = %s",
            (hash_token(token),),
        ).fetchone()


def run_sql(migrated_db: str, statement: str, *params: object) -> None:
    with psycopg.connect(migrated_db, autocommit=True) as conn:
        conn.execute(statement, params)


class TestHealth:
    def test_healthz(self, client):
        assert client.get("/healthz").json() == {"status": "ok"}

    def test_readyz_when_migrated(self, client):
        response = client.get("/readyz")
        assert response.status_code == 200
        assert response.json() == {"status": "ready"}

    def test_readyz_lists_pending_migrations(self, empty_db):
        with TestClient(create_app(settings_for(empty_db)), base_url=BASE) as c:
            response = c.get("/readyz")
        assert response.status_code == 503
        assert response.json()["reason"] == "migrations are pending"
        assert "0001_initial.sql" in response.json()["pending"]

    def test_readyz_when_the_database_is_down(self):
        down = "postgresql://nobody:x@127.0.0.1:1/nowhere?connect_timeout=1"
        with TestClient(create_app(settings_for(down)), base_url=BASE) as c:
            response = c.get("/readyz")
        assert response.status_code == 503
        assert response.json()["reason"] == "the database isn't answering"


class TestSignIn:
    def test_dev_login_starts_a_session(self, client, user, migrated_db):
        response = sign_in(client, user["email"].upper())  # email addresses ignore case
        assert response.status_code == 200
        assert response.json() == {
            "id": user["id"], "email": user["email"], "role": "staff", "employee_id": None,
        }  # fmt: skip
        assert client.get("/auth/me").json()["id"] == user["id"]

        token = client.cookies[COOKIE]
        row = session_row(migrated_db, token)
        assert row is not None and row[1] == user["id"]  # only the token's hash is stored

    def test_the_cookie_is_locked_down(self, client, user):
        cookie = sign_in(client, user["email"]).headers["set-cookie"]
        assert cookie.startswith(f"{COOKIE}=")
        for attribute in ["HttpOnly", "Secure", "SameSite=lax", "Path=/", "Max-Age=43200"]:
            assert attribute in cookie

    def test_locally_the_cookie_works_over_plain_http(self, app_db_url, user):
        settings = settings_for(app_db_url, env="local", allowed_origins="http://localhost:8000")
        with TestClient(create_app(settings), base_url="http://localhost:8000") as c:
            cookie = c.post(
                "/auth/dev-login",
                json={"email": user["email"]},
                headers={"Origin": "http://localhost:8000"},
            ).headers["set-cookie"]
        assert cookie.startswith("wfm_session=")
        assert "Secure" not in cookie

    def test_unknown_and_inactive_users_cannot_sign_in(self, client, make_user):
        assert sign_in(client, "nobody@example.com").status_code == 401
        inactive = f"gone-{secrets.token_hex(3)}@example.com"
        make_user("staff", email=inactive, active=False)
        assert sign_in(client, inactive).status_code == 401

    def test_signing_in_is_audited(self, client, user, migrated_db):
        sign_in(client, user["email"])
        session_id = session_row(migrated_db, client.cookies[COOKIE])[0]  # type: ignore[index]
        with psycopg.connect(migrated_db) as conn:
            entry = conn.execute(
                "SELECT action, app_user_id, after_data FROM audit_log"
                " WHERE entity_type = 'app_session' AND entity_id = %s",
                (str(session_id),),
            ).fetchone()
        assert entry == ("auth.login", user["id"], {"method": "dev"})


class TestSessions:
    def test_no_session_means_401(self, client):
        assert client.get("/auth/me").status_code == 401

    def test_a_made_up_token_means_401(self, client):
        client.cookies.set(COOKIE, "made-up-token")
        assert client.get("/auth/me").status_code == 401

    def test_signing_out_ends_the_session_for_good(self, client, user, migrated_db):
        sign_in(client, user["email"])
        token = client.cookies[COOKIE]
        response = client.post("/auth/logout", headers=FROM_APP)
        assert response.status_code == 204
        assert COOKIE not in client.cookies
        assert session_row(migrated_db, token)[2] == "logout"  # type: ignore[index]

        client.cookies.set(COOKIE, token)  # replaying the old cookie doesn't work
        assert client.get("/auth/me").status_code == 401

    def test_deactivating_someone_signs_them_out_at_once(self, client, user, migrated_db):
        sign_in(client, user["email"])
        run_sql(migrated_db, "UPDATE app_user SET is_active = false WHERE id = %s", user["id"])
        assert client.get("/auth/me").status_code == 401

    def test_sessions_expire(self, client, user, migrated_db):
        sign_in(client, user["email"])
        run_sql(
            migrated_db,
            "UPDATE app_session SET created_at = now() - interval '13 hours',"
            " last_seen_at = now() - interval '5 minutes', expires_at = now() - interval '1 hour'"
            " WHERE token_hash = %s",
            hash_token(client.cookies[COOKIE]),
        )
        assert client.get("/auth/me").status_code == 401

    def test_idle_sessions_end(self, client, user, migrated_db):
        sign_in(client, user["email"])
        run_sql(
            migrated_db,
            "UPDATE app_session SET created_at = now() - interval '7 hours',"
            " last_seen_at = now() - interval '361 minutes' WHERE token_hash = %s",
            hash_token(client.cookies[COOKIE]),
        )
        assert client.get("/auth/me").status_code == 401

    def test_using_a_session_keeps_it_alive(self, client, user, migrated_db):
        sign_in(client, user["email"])
        token_hash = hash_token(client.cookies[COOKIE])
        run_sql(
            migrated_db,
            "UPDATE app_session SET created_at = now() - interval '2 hours',"
            " last_seen_at = now() - interval '10 minutes' WHERE token_hash = %s",
            token_hash,
        )
        assert client.get("/auth/me").status_code == 200
        with psycopg.connect(migrated_db) as conn:
            idle = conn.execute(
                "SELECT now() - last_seen_at < interval '1 minute' FROM app_session"
                " WHERE token_hash = %s",
                (token_hash,),
            ).fetchone()
        assert idle == (True,)


class TestAccess:
    def test_roles_are_checked(self, client, make_user):
        staff = f"staff-{secrets.token_hex(3)}@example.com"
        manager = f"manager-{secrets.token_hex(3)}@example.com"
        make_user("staff", email=staff)
        manager_id = make_user("manager", email=manager)

        assert client.get("/test/managers-only").status_code == 401
        sign_in(client, staff)
        assert client.get("/test/managers-only").status_code == 403
        sign_in(client, manager)
        assert client.get("/test/managers-only").json() == {"id": manager_id}

    @pytest.mark.parametrize(
        "headers",
        [{}, {"Origin": "https://evil.example"}, {"Referer": "https://evil.example/page"}],
    )
    def test_changes_from_other_sites_are_refused(self, client, user, headers):
        sign_in(client, user["email"])
        assert client.post("/auth/logout", headers=headers).status_code == 403
        assert client.get("/auth/me").status_code == 200  # still signed in

    def test_a_referer_from_the_app_is_accepted(self, client, user):
        sign_in(client, user["email"])
        assert client.post("/auth/logout", headers={"Referer": f"{BASE}/roster"}).status_code == 204

    def test_dev_login_is_refused_from_other_sites(self, client, user):
        response = client.post(
            "/auth/dev-login",
            json={"email": user["email"]},
            headers={"Origin": "https://evil.example"},
        )
        assert response.status_code == 403


@pytest.mark.parametrize("env", ["staging", "production"])
def test_outside_development_there_is_no_dev_login_and_no_api_docs(app_db_url, user, env):
    settings = settings_for(app_db_url, env=env, allowed_origins="https://wfm.example.com.au")
    with TestClient(create_app(settings), base_url="https://wfm.example.com.au") as c:
        response = c.post(
            "/auth/dev-login",
            json={"email": user["email"]},
            headers={"Origin": "https://wfm.example.com.au"},
        )
        assert response.status_code == 404
        assert c.get("/docs").status_code == 404
        assert c.get("/openapi.json").status_code == 404


def test_dev_login_can_be_switched_off_locally(app_db_url, user):
    settings = settings_for(app_db_url, dev_login_enabled=False)
    with TestClient(create_app(settings), base_url=BASE) as c:
        assert sign_in(c, user["email"]).status_code == 404
