"""Settings, read from WFM_* environment variables and, for local work, a .env file.

Local and test environments get working defaults, so a fresh clone runs without
any configuration. Staging and production get no defaults: anything they need
must be set explicitly, and settings that are only safe on a developer's
machine are refused.

Secrets are SecretStr, so they show as '**********' in logs and tracebacks.
"""

from typing import Annotated, Any, Literal, Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

from app.core.crypto import TokenCipher, parse_keys

Environment = Literal["local", "test", "staging", "production"]
DEV_ENVIRONMENTS: tuple[Environment, ...] = ("local", "test")

# Local-only credentials, matching compose.yaml and `wfm db setup`.
LOCAL_DATABASE_URL = "postgresql://wfm_api:wfm_api@localhost:5432/wfm"
LOCAL_MIGRATION_DATABASE_URL = "postgresql://wfm_owner:wfm_owner@localhost:5432/wfm"
LOCAL_ADMIN_DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/postgres"
LOCAL_ORIGINS = ("http://localhost:8000", "http://127.0.0.1:8000")


class ConfigError(Exception):
    """A setting this command needs is missing."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="WFM_",
        env_file=".env",
        extra="ignore",
        # Validation errors would otherwise echo the raw input, secrets included.
        hide_input_in_errors=True,
    )

    env: Environment = "local"

    # --- Database
    # The app's own login, a member of the wfm_app role (see 0002_app_role.sql).
    database_url: SecretStr | None = None
    # The schema owner, used by `wfm db migrate`.
    migration_database_url: SecretStr | None = None
    # A superuser, used by `wfm db setup` and `wfm db test`. Local and test only.
    admin_database_url: SecretStr | None = None

    # --- Browser sessions
    # Sites allowed to send changes to the API (protection against cross-site
    # request forgery). Comma-separated, like https://wfm.example.com.au
    allowed_origins: Annotated[tuple[str, ...], NoDecode] = ()
    # Send the session cookie over HTTPS only. Off by default only for local work.
    cookie_secure: bool = True
    # A session ends after this long without a request, or this long in total.
    session_idle_minutes: int = Field(default=360, ge=5, le=24 * 60)
    session_max_hours: int = Field(default=12, ge=1, le=24 * 30)
    # Sign in with an email address alone, until the real login is chosen.
    # Local and test only.
    dev_login_enabled: bool = False

    # --- Secrets for later steps
    # Keys for encrypting Xero tokens (Step 5), comma-separated, newest first.
    token_encryption_keys: SecretStr | None = None
    # Aircall API credentials (Step 6).
    aircall_api_id: SecretStr | None = None
    aircall_api_token: SecretStr | None = None
    # The Xero app's credentials (Step 5).
    xero_client_id: str | None = None
    xero_client_secret: SecretStr | None = None

    @model_validator(mode="before")
    @classmethod
    def _environment_defaults(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        env = data.get("env", "local")
        data.setdefault("cookie_secure", env != "local")
        if env in DEV_ENVIRONMENTS:
            data.setdefault("database_url", LOCAL_DATABASE_URL)
            data.setdefault("migration_database_url", LOCAL_MIGRATION_DATABASE_URL)
            data.setdefault("admin_database_url", LOCAL_ADMIN_DATABASE_URL)
            data.setdefault("allowed_origins", LOCAL_ORIGINS)
            data.setdefault("dev_login_enabled", True)
        return data

    @field_validator("allowed_origins", mode="before")
    @classmethod
    def _split_origins(cls, value: Any) -> Any:
        if isinstance(value, str):
            return tuple(o.strip().rstrip("/") for o in value.split(",") if o.strip())
        return value

    @field_validator("token_encryption_keys")
    @classmethod
    def _check_keys(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None:
            parse_keys(value.get_secret_value())
        return value

    @model_validator(mode="after")
    def _safe_outside_development(self) -> Self:
        if self.is_dev:
            return self
        problems = []
        if self.dev_login_enabled:
            problems.append("WFM_DEV_LOGIN_ENABLED must be off")
        if not self.cookie_secure:
            problems.append("WFM_COOKIE_SECURE must be on")
        if not self.allowed_origins:
            problems.append("WFM_ALLOWED_ORIGINS must be set")
        elif any(not o.startswith("https://") for o in self.allowed_origins):
            problems.append("WFM_ALLOWED_ORIGINS must all start with https://")
        if self.admin_database_url is not None:
            problems.append("WFM_ADMIN_DATABASE_URL is for local and test only")
        if problems:
            raise ValueError(f"unsafe settings for {self.env}: {'; '.join(problems)}")
        return self

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

    def token_cipher(self) -> TokenCipher:
        return TokenCipher(_require(self.token_encryption_keys, "WFM_TOKEN_ENCRYPTION_KEYS"))


def _require(value: SecretStr | None, name: str) -> str:
    if value is None:
        raise ConfigError(f"{name} is not set.")
    return value.get_secret_value()
