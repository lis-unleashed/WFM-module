"""Health checks for the hosting platform."""

from typing import cast

import psycopg
from fastapi import APIRouter, Request, Response, status
from psycopg_pool import ConnectionPool, PoolTimeout

from app.core import migrations
from app.core.db import Connection

router = APIRouter(tags=["health"])


@router.get("/healthz")
def healthz() -> dict[str, str]:
    """The app is running. Doesn't touch the database."""
    return {"status": "ok"}


@router.get("/readyz")
def readyz(request: Request, response: Response) -> dict[str, object]:
    """Ready for traffic: the database answers and every migration has been applied."""
    pool = cast(ConnectionPool[Connection], request.app.state.pool)
    on_disk = cast(list[migrations.Migration], request.app.state.migrations)
    try:
        with pool.connection(timeout=2) as conn:
            todo = migrations.pending(on_disk, migrations.applied(conn))
    except (psycopg.Error, PoolTimeout):
        return _unavailable(response, "the database isn't answering")
    except migrations.MigrationError:
        return _unavailable(response, "the database's migrations don't match this version")
    if todo:
        return _unavailable(response, "migrations are pending", pending=[m.filename for m in todo])
    return {"status": "ready"}


def _unavailable(response: Response, reason: str, **detail: object) -> dict[str, object]:
    response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {"status": "unavailable", "reason": reason, **detail}
