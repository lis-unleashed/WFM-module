"""Settings, read from WFM_* environment variables and, for local work, a .env file.

Local and test environments get working defaults, so a fresh clone runs without
any configuration. Staging and production get no defaults: anything they need
must be set explicitly.
"""

from typing import Any, Literal

from pydantic import SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["local", "test", "staging", "production"]
DEV_ENVIRONMENTS: tuple[Environment, ...] = ("local", "test")

# Local-only credentials, matching compose.yaml and `wfm db setup`.
LOCAL_DATABASE_URL = "postgresql://wfm_api:wfm_api@localhost:5432/wfm"
LOCAL_MIGRATION_DATABASE_URL = "postgresql://wfm_owner:wfm_owner@localhost:5432/wfm"
LOCAL_ADMIN_DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/postgres"


class ConfigError(Exception):
    """A setting this command needs is missing or unsafe."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="WFM_",
        env_file=".env",
        extra="ignore",
        # Validation errors would otherwise echo the raw input, secrets included.
        hide_input_in_errors=True,
    )

    env: Environment = "local"

    # The app's own login, a member of the wfm_app role (see 0002_app_role.sql).
    database_url: SecretStr | None = None
    # The schema owner, used by `wfm db migrate`.
    migration_database_url: SecretStr | None = None
    # A superuser, used by `wfm db setup` and `wfm db test`. Local and test only.
    admin_database_url: SecretStr | None = None

    @model_validator(mode="before")
    @classmethod
    def _local_defaults(cls, data: Any) -> Any:
        if isinstance(data, dict) and data.get("env", "local") in DEV_ENVIRONMENTS:
            data.setdefault("database_url", LOCAL_DATABASE_URL)
            data.setdefault("migration_database_url", LOCAL_MIGRATION_DATABASE_URL)
            data.setdefault("admin_database_url", LOCAL_ADMIN_DATABASE_URL)
        return data

    @property
    def is_dev(self) -> bool:
        return self.env in DEV_ENVIRONMENTS

    def require_database_url(self) -> str:
        return _require(self.database_url, "WFM_DATABASE_URL")

    def require_migration_database_url(self) -> str:
        return _require(self.migration_database_url, "WFM_MIGRATION_DATABASE_URL")

    def require_admin_database_url(self) -> str:
        if not self.is_dev:
            raise ConfigError(f"This command is for local and test use only (WFM_ENV={self.env}).")
        return _require(self.admin_database_url, "WFM_ADMIN_DATABASE_URL")


def _require(value: SecretStr | None, name: str) -> str:
    if value is None:
        raise ConfigError(f"{name} is not set.")
    return value.get_secret_value()
