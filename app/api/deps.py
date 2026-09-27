"""What routes can ask for: the settings, a database connection, the signed-in user."""

import ipaddress
from collections.abc import Callable, Iterator
from datetime import timedelta
from typing import Annotated, cast
from urllib.parse import urlsplit

from fastapi import Depends, HTTPException, Request, status
from psycopg_pool import ConnectionPool

from app.core import sessions
from app.core.db import Connection
from app.core.sessions import CurrentUser, Role
from app.core.settings import Settings

SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})


def get_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)


def get_conn(request: Request) -> Iterator[Connection]:
    """A pooled connection for this request, in autocommit mode. Routes that change
    data do it inside `with conn.transaction():`, together with its audit entry."""
    pool = cast(ConnectionPool[Connection], request.app.state.pool)
    with pool.connection() as conn:
        yield conn


SettingsDep = Annotated[Settings, Depends(get_settings)]
Conn = Annotated[Connection, Depends(get_conn)]


def session_cookie_name(settings: Settings) -> str:
    # With the __Host- prefix, browsers insist on Secure, Path=/ and no Domain.
    return "__Host-wfm_session" if settings.cookie_secure else "wfm_session"


def client_ip(request: Request) -> str | None:
    """The caller's IP address, if it is one (behind a proxy, run uvicorn with --proxy-headers)."""
    host = request.client.host if request.client else None
    try:
        return str(ipaddress.ip_address(host)) if host else None
    except ValueError:
        return None


def require_same_origin(request: Request, settings: SettingsDep) -> None:
    """Refuses requests that change data unless they come from one of our own pages.

    This is the defence against cross-site request forgery, on top of the
    SameSite cookie. Browsers send an Origin header with such requests; a
    Referer from an allowed origin is accepted too.
    """
    if request.method in SAFE_METHODS:
        return
    origin = request.headers.get("origin")
    if origin is None and (referer := request.headers.get("referer")):
        parts = urlsplit(referer)
        origin = f"{parts.scheme}://{parts.netloc}"
    if origin is None or origin.rstrip("/") not in settings.allowed_origins:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This request didn't come from the WFM app.")


def current_user(request: Request, conn: Conn, settings: SettingsDep) -> CurrentUser:
    require_same_origin(request, settings)
    token = request.cookies.get(session_cookie_name(settings))
    idle_limit = timedelta(minutes=settings.session_idle_minutes)
    user = sessions.authenticate(conn, token, idle_limit=idle_limit) if token else None
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Please sign in.")
    return user


UserDep = Annotated[CurrentUser, Depends(current_user)]


def require_role(*roles: Role) -> Callable[[CurrentUser], CurrentUser]:
    """A dependency that lets through only users with one of these roles.

        ManagerDep = Annotated[CurrentUser, Depends(require_role("manager", "admin"))]

    Each route names every role it allows; no role implies another.
    """
    allowed = frozenset(roles)

    def check(user: UserDep) -> CurrentUser:
        if user.role not in allowed:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "You don't have access to this.")
        return user

    return check
