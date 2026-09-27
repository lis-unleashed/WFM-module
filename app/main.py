"""The web app. `make run` starts it locally; in production run:

uvicorn app.main:create_app --factory --proxy-headers
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api import auth, health
from app.core import migrations
from app.core.db import create_pool
from app.core.settings import Settings


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    pool = create_pool(settings.require_database_url())

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        pool.open()
        try:
            yield
        finally:
            pool.close()

    app = FastAPI(
        title="Unleashed WFM",
        lifespan=lifespan,
        # The API docs are for developers, so they're only served locally.
        docs_url="/docs" if settings.is_dev else None,
        redoc_url=None,
        openapi_url="/openapi.json" if settings.is_dev else None,
    )
    app.state.settings = settings
    app.state.pool = pool
    app.state.migrations = migrations.discover()
    app.include_router(health.router)
    app.include_router(auth.router)
    if settings.dev_login_enabled:
        app.include_router(auth.dev_router)
    return app
