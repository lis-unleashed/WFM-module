import subprocess
from pathlib import Path

import pytest

from app.cli import main
from app.core.migrations import edited_since


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", *args],
        cwd=repo, check=True, capture_output=True,
    )  # fmt: skip


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A repository with 0001 on main, and a feature branch checked out."""
    (tmp_path / "db" / "migrations").mkdir(parents=True)
    (tmp_path / "db" / "migrations" / "0001_initial.sql").write_text("CREATE TABLE a (id int);\n")
    git(tmp_path, "init", "-q", "-b", "main")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-q", "-m", "initial")
    git(tmp_path, "checkout", "-q", "-b", "feature")
    return tmp_path


def edited(repo: Path) -> list[tuple[str, str]]:
    return edited_since("main", repo / "db" / "migrations", repo=repo)


def test_adding_a_migration_is_fine(repo):
    (repo / "db" / "migrations" / "0002_next.sql").write_text("CREATE TABLE b (id int);\n")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "add 0002")
    assert edited(repo) == []


def test_editing_a_migration_from_main_is_caught_even_before_committing(repo):
    (repo / "db" / "migrations" / "0001_initial.sql").write_text("CREATE TABLE a (id bigint);\n")
    assert edited(repo) == [("changed", "db/migrations/0001_initial.sql")]


def test_renaming_a_migration_from_main_is_caught(repo):
    git(repo, "mv", "db/migrations/0001_initial.sql", "db/migrations/0001_renamed.sql")
    assert edited(repo) == [("deleted", "db/migrations/0001_initial.sql")]


def test_migrations_added_to_main_after_branching_dont_count(repo):
    git(repo, "checkout", "-q", "main")
    (repo / "db" / "migrations" / "0002_on_main.sql").write_text("CREATE TABLE b (id int);\n")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "add 0002 on main")
    git(repo, "checkout", "-q", "feature")
    assert edited(repo) == []


def test_the_command_explains_an_unknown_branch(capsys):
    assert main(["db", "check-frozen", "--against", "no-such-branch"]) == 1
    assert "couldn't compare with no-such-branch" in capsys.readouterr().err
