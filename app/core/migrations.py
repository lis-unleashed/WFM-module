"""Applies the numbered SQL files in db/migrations, in order, exactly once each.

Each file runs in one transaction together with its row in schema_migrations,
so a migration is either applied and recorded, or not applied at all. The
runner keeps a checksum of every file it applies and refuses to continue if
an applied file has changed, so "never edit a deployed migration" is enforced
rather than just written down. There are no down migrations: a mistake is
fixed with a new migration.
"""

import hashlib
import re
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import psycopg
from psycopg import sql

from app.core.paths import MIGRATIONS_DIR, REPO_ROOT

FILENAME = re.compile(r"^(?P<version>\d{4})_[a-z0-9_]+\.sql$")

# Held while migrating so two deploys can't migrate the same database at once.
# Any constant works, as long as every copy of the runner uses the same one.
LOCK_KEY = 5_782_300_661

BOOKKEEPING = """
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     text PRIMARY KEY,
  filename    text NOT NULL,
  checksum    text NOT NULL,          -- SHA-256 of the file as applied
  applied_at  timestamptz NOT NULL DEFAULT now(),
  applied_by  text NOT NULL DEFAULT current_user
)
"""


class MigrationError(Exception):
    """The files and the database disagree, or a migration failed and was rolled back."""


@dataclass(frozen=True)
class Migration:
    version: str
    filename: str
    sql: bytes
    checksum: str


@dataclass(frozen=True)
class AppliedMigration:
    version: str
    filename: str
    checksum: str
    applied_at: datetime


def checksum(content: bytes) -> str:
    # Line endings are normalised so a Windows checkout gives the same answer.
    return hashlib.sha256(content.replace(b"\r\n", b"\n")).hexdigest()


def discover(directory: Path = MIGRATIONS_DIR) -> list[Migration]:
    """The migration files in order. Raises if a name is malformed or a number is reused."""
    migrations: list[Migration] = []
    seen: dict[str, str] = {}
    for path in sorted(directory.glob("*.sql")):
        match = FILENAME.match(path.name)
        if match is None:
            raise MigrationError(
                f"{path.name}: migration files are named like 0002_short_description.sql"
            )
        version = match["version"]
        if version in seen:
            raise MigrationError(f"{seen[version]} and {path.name} have the same number.")
        seen[version] = path.name
        content = path.read_bytes()
        migrations.append(Migration(version, path.name, content, checksum(content)))
    return migrations


def applied(conn: psycopg.Connection[Any]) -> dict[str, AppliedMigration]:
    """What schema_migrations says has been applied: nothing, on a new database."""
    row = conn.execute("SELECT to_regclass('schema_migrations')").fetchone()
    if row is None or row[0] is None:
        return {}
    rows = conn.execute(
        "SELECT version, filename, checksum, applied_at FROM schema_migrations ORDER BY version"
    ).fetchall()
    return {r[0]: AppliedMigration(*r) for r in rows}


def pending(migrations: list[Migration], done: dict[str, AppliedMigration]) -> list[Migration]:
    """The migrations still to apply. Raises MigrationError if files and database disagree."""
    on_disk = {m.version: m for m in migrations}
    problems: list[str] = []
    for version, record in done.items():
        migration = on_disk.get(version)
        if migration is None:
            problems.append(f"{record.filename} has been applied but its file is missing.")
        elif migration.filename != record.filename:
            problems.append(f"{record.filename} has been applied but is now {migration.filename}.")
        elif migration.checksum != record.checksum:
            problems.append(
                f"{migration.filename} has changed since it was applied on "
                f"{record.applied_at:%d %b %Y}. Undo the edit and make the change "
                "in a new migration."
            )
    todo = [m for m in migrations if m.version not in done]
    if done:
        latest = done[max(done)]
        problems.extend(
            f"{m.filename} is numbered below {latest.filename}, which has already been "
            "applied. Give it the next free number."
            for m in todo
            if m.version < latest.version
        )
    if problems:
        raise MigrationError("\n".join(problems))
    return todo


def status(
    conninfo: str, directory: Path = MIGRATIONS_DIR
) -> tuple[list[AppliedMigration], list[Migration]]:
    """(applied, pending). Raises MigrationError if files and database disagree."""
    migrations = discover(directory)
    with psycopg.connect(conninfo, autocommit=True) as conn:
        done = applied(conn)
    return list(done.values()), pending(migrations, done)


def migrate(
    conninfo: str,
    directory: Path = MIGRATIONS_DIR,
    *,
    role: str | None = None,
    on_applied: Callable[[Migration, float], None] | None = None,
    on_wait: Callable[[], None] | None = None,
) -> list[Migration]:
    """Applies the pending migrations and returns them.

    `role`, if given, is taken with SET ROLE first, so a superuser connection
    can migrate exactly as the schema owner would.
    """
    migrations = discover(directory)
    with psycopg.connect(conninfo, autocommit=True) as conn:
        if role is not None:
            conn.execute(sql.SQL("SET ROLE {}").format(sql.Identifier(role)))
        if not _try_lock(conn):
            if on_wait is not None:
                on_wait()
            conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
        try:
            conn.execute(BOOKKEEPING)
            todo = pending(migrations, applied(conn))
            for migration in todo:
                started = time.monotonic()
                try:
                    with conn.transaction():
                        conn.execute(migration.sql)
                        conn.execute(
                            "INSERT INTO schema_migrations (version, filename, checksum)"
                            " VALUES (%s, %s, %s)",
                            (migration.version, migration.filename, migration.checksum),
                        )
                except psycopg.Error as e:
                    raise MigrationError(
                        f"{migration.filename} failed and was rolled back: {e}"
                    ) from e
                if on_applied is not None:
                    on_applied(migration, time.monotonic() - started)
            return todo
        finally:
            if not conn.broken:
                conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))


def _try_lock(conn: psycopg.Connection[Any]) -> bool:
    row = conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_KEY,)).fetchone()
    return bool(row and row[0])


def edited_since(
    base: str, directory: Path = MIGRATIONS_DIR, *, repo: Path = REPO_ROOT
) -> list[tuple[str, str]]:
    """Migration files that exist on `base` but have since been changed or removed.

    Compares the point where this branch left `base` with the working tree, so
    migrations added to `base` later don't count. Returns (status, path) pairs,
    where status is "changed" or "deleted"; a rename shows as a deletion.
    """
    merge_base = _git(repo, "merge-base", base, "HEAD").strip()
    diff = _git(
        repo,
        "diff",
        "--name-status",
        "--no-renames",
        "--diff-filter=MD",
        merge_base,
        "--",
        str(directory.relative_to(repo)),
    )
    labels = {"M": "changed", "D": "deleted"}
    return [
        (labels[status], path)
        for status, path in (line.split("\t", 1) for line in diff.splitlines() if line)
    ]


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout
