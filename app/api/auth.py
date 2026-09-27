"""Signing in and out.

How people sign in is still to be decided (Google or Microsoft single sign-on,
or email and password; handover section 9). Until then there's a dev-only
sign-in by email address, which exists only in local and test. Whatever real
sign-in is added later ends the same way: sessions.start(), an audit entry and
the session cookie, as dev_login does below.
"""

from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel

from app.api.deps import (
    Conn,
    SettingsDep,
    UserDep,
    client_ip,
    require_same_origin,
    session_cookie_name,
)
from app.core import audit, sessions
from app.core.sessions import Role
from app.core.settings import Settings

router = APIRouter(prefix="/auth", tags=["auth"])
dev_router = APIRouter(prefix="/auth", tags=["auth"])


class UserOut(BaseModel):
    id: int
    email: str
    role: Role
    employee_id: int | None


@router.get("/me")
def me(user: UserDep) -> UserOut:
    return UserOut(id=user.id, email=user.email, role=user.role, employee_id=user.employee_id)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    request: Request, response: Response, user: UserDep, conn: Conn, settings: SettingsDep
) -> None:
    with conn.transaction():
        sessions.end(conn, user.session_id, reason="logout")
        audit.record(
            conn,
            action="auth.logout",
            entity_type="app_session",
            entity_id=user.session_id,
            actor_user_id=user.id,
            ip_address=client_ip(request),
        )
    response.delete_cookie(
        session_cookie_name(settings),
        path="/",
        secure=settings.cookie_secure,
        httponly=True,
        samesite="lax",
    )


class DevLogin(BaseModel):
    email: str


@dev_router.post("/dev-login", dependencies=[Depends(require_same_origin)])
def dev_login(
    body: DevLogin, request: Request, response: Response, conn: Conn, settings: SettingsDep
) -> UserOut:
    """Signs in as any active user by email address alone. Local and test only."""
    row = conn.execute(
        "SELECT id, email, role, employee_id FROM app_user WHERE email = %s::citext AND is_active",
        (body.email,),
    ).fetchone()
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "No active user has that email address.")
    user = UserOut(id=row[0], email=row[1], role=row[2], employee_id=row[3])
    ip = client_ip(request)
    with conn.transaction():
        new = sessions.start(
            conn,
            user_id=user.id,
            lifetime=timedelta(hours=settings.session_max_hours),
            ip_address=ip,
            user_agent=request.headers.get("user-agent"),
        )
        conn.execute("UPDATE app_user SET last_login_at = now() WHERE id = %s", (user.id,))
        audit.record(
            conn,
            action="auth.login",
            entity_type="app_session",
            entity_id=new.id,
            actor_user_id=user.id,
            after={"method": "dev"},
            ip_address=ip,
        )
    _set_session_cookie(response, settings, new)
    return user


def _set_session_cookie(response: Response, settings: Settings, new: sessions.NewSession) -> None:
    response.set_cookie(
        session_cookie_name(settings),
        new.token,
        max_age=settings.session_max_hours * 3600,
        path="/",
        secure=settings.cookie_secure,
        httponly=True,
        samesite="lax",
    )
