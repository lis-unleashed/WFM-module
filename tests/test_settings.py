import os
import re

import pytest
from pydantic import ValidationError

from app.cli import main
from app.core.crypto import generate_key
from app.core.settings import (
    LOCAL_ADMIN_DATABASE_URL,
    LOCAL_DATABASE_URL,
    LOCAL_ORIGINS,
    ConfigError,
    Settings,
)

PRODUCTION = {
    "env": "production",
    "database_url": "postgresql://wfm_api:TOPSECRET@db.internal/wfm",
    "allowed_origins": "https://wfm.example.com.au",
}


@pytest.fixture(autouse=True)
def no_wfm_environment(monkeypatch, tmp_path):
    """Each test starts with no WFM_* variables and no .env file."""
    for name in list(os.environ):
        if name.startswith("WFM_"):
            monkeypatch.delenv(name)
    monkeypatch.chdir(tmp_path)


def settings(**values: object) -> Settings:
    return Settings(**values)  # type: ignore[arg-type]


class TestDevelopment:
    def test_a_fresh_clone_needs_no_configuration(self):
        s = settings()
        assert s.env == "local"
        assert s.require_database_url() == LOCAL_DATABASE_URL
        assert s.require_admin_database_url() == LOCAL_ADMIN_DATABASE_URL
        assert s.allowed_origins == LOCAL_ORIGINS
        assert s.dev_login_enabled
        assert not s.cookie_secure  # so http://localhost works in every browser

    def test_the_test_environment_uses_secure_cookies(self):
        s = settings(env="test")
        assert s.cookie_secure
        assert s.dev_login_enabled

    def test_values_come_from_the_environment(self, monkeypatch):
        monkeypatch.setenv("WFM_ENV", "test")
        monkeypatch.setenv("WFM_SESSION_IDLE_MINUTES", "30")
        monkeypatch.setenv("WFM_ALLOWED_ORIGINS", "https://a.example.com, https://b.example.com/")
        s = Settings()
        assert s.env == "test"
        assert s.session_idle_minutes == 30
        assert s.allowed_origins == ("https://a.example.com", "https://b.example.com")

    def test_values_come_from_a_local_env_file(self, tmp_path):
        (tmp_path / ".env").write_text("WFM_SESSION_MAX_HOURS=8\n")
        assert Settings().session_max_hours == 8


@pytest.mark.parametrize("env", ["staging", "production"])
class TestOutsideDevelopment:
    def test_a_minimal_valid_setup(self, env):
        s = settings(**{**PRODUCTION, "env": env})
        assert s.cookie_secure
        assert not s.dev_login_enabled
        assert s.admin_database_url is None
        assert s.migration_database_url is None  # no defaults outside development

    def test_missing_urls_are_reported_by_name(self, env):
        s = settings(env=env, allowed_origins="https://wfm.example.com.au")
        with pytest.raises(ConfigError, match="WFM_DATABASE_URL is not set"):
            s.require_database_url()
        with pytest.raises(ConfigError, match="WFM_MIGRATION_DATABASE_URL is not set"):
            s.require_migration_database_url()

    def test_admin_tools_are_refused(self, env):
        with pytest.raises(ConfigError, match="local and test use only"):
            settings(**{**PRODUCTION, "env": env}).require_admin_database_url()

    @pytest.mark.parametrize(
        ("change", "problem"),
        [
            ({"dev_login_enabled": True}, "WFM_DEV_LOGIN_ENABLED must be off"),
            ({"cookie_secure": False}, "WFM_COOKIE_SECURE must be on"),
            ({"allowed_origins": ""}, "WFM_ALLOWED_ORIGINS must be set"),
            ({"allowed_origins": "http://wfm.example.com.au"}, "must all start with https://"),
            ({"admin_database_url": "postgresql://x@y/z"}, "WFM_ADMIN_DATABASE_URL is for local"),
        ],
    )
    def test_unsafe_settings_are_refused(self, env, change, problem):
        with pytest.raises(ValidationError, match=re.escape(problem)):
            settings(**{**PRODUCTION, "env": env, **change})


class TestSecrets:
    def test_secrets_are_hidden_when_printed(self):
        s = settings(**PRODUCTION, xero_client_secret="XEROSECRET")
        assert "TOPSECRET" not in repr(s)
        assert "XEROSECRET" not in repr(s)
        assert s.require_database_url().endswith("TOPSECRET@db.internal/wfm")

    def test_validation_errors_do_not_echo_secrets(self):
        with pytest.raises(ValidationError) as error:
            settings(**PRODUCTION, dev_login_enabled=True)
        assert "TOPSECRET" not in str(error.value)

    def test_encryption_keys_are_checked_without_revealing_them(self):
        good = generate_key()
        with pytest.raises(ValidationError, match="encryption key 2 isn't a valid key") as error:
            settings(token_encryption_keys=f"{good},not-a-real-key")
        assert good not in str(error.value)
        assert "not-a-real-key" not in str(error.value)

    def test_the_token_cipher_needs_keys(self):
        with pytest.raises(ConfigError, match="WFM_TOKEN_ENCRYPTION_KEYS is not set"):
            settings().token_cipher()
        cipher = settings(token_encryption_keys=generate_key()).token_cipher()
        assert cipher.decrypt(cipher.encrypt("refresh-token")) == "refresh-token"


def test_the_cli_reports_invalid_settings_without_a_traceback(monkeypatch, capsys):
    monkeypatch.setenv("WFM_ENV", "production")
    monkeypatch.setenv("WFM_DEV_LOGIN_ENABLED", "true")
    assert main(["db", "status"]) == 1
    assert "WFM_DEV_LOGIN_ENABLED must be off" in capsys.readouterr().err


def test_the_cli_generates_usable_keys(capsys):
    assert main(["generate-key"]) == 0
    key = capsys.readouterr().out.strip()
    assert settings(token_encryption_keys=key).token_cipher()
