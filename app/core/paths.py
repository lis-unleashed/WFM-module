"""Where things live in the repository."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS_DIR = REPO_ROOT / "db" / "migrations"
SQL_TESTS_DIR = REPO_ROOT / "db" / "tests"
COMPOSE_FILE = REPO_ROOT / "compose.yaml"
