import re
from pathlib import Path

import psycopg
import pytest

from app.core import migrations
from app.core.dbtools import OWNER_ROLE
from app.core.migrations import LOCK_KEY, MigrationError


def write(directory: Path, name: str, sql: str) -> None:
    (directory / name).write_text(sql, encoding="utf-8")


def tables(conninfo: str) -> dict[str, str]:
    """Table name -> owner, in the public schema."""
    with psycopg.connect(conninfo) as conn:
        rows = conn.execute(
            "SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public'"
        ).fetchall()
    return dict(rows)


@pytest.fixture
def migration_dir(tmp_path: Path) -> Path:
    write(tmp_path, "0001_first.sql", "CREATE TABLE thing (id int PRIMARY KEY);")
    write(tmp_path, "0002_second.sql", "ALTER TABLE thing ADD COLUMN name text;")
    return tmp_path


class TestDiscover:
    def test_files_are_in_number_order(self, tmp_path):
        write(tmp_path, "0010_later.sql", "")
        write(tmp_path, "0002_earlier.sql", "")
        assert [m.version for m in migrations.discover(tmp_path)] == ["0002", "0010"]

    def test_names_must_follow_the_pattern(self, tmp_path):
        write(tmp_path, "2_add_things.sql", "")
        with pytest.raises(
            MigrationError, match=re.escape("named like 0002_short_description.sql")
        ):
            migrations.discover(tmp_path)

    def test_numbers_cannot_be_reused(self, tmp_path):
        write(tmp_path, "0002_one.sql", "")
        write(tmp_path, "0002_other.sql", "")
        with pytest.raises(MigrationError, match=re.escape("have the same number")):
            migrations.discover(tmp_path)

    def test_checksum_ignores_windows_line_endings(self):
        assert migrations.checksum(b"a;\r\nb;\r\n") == migrations.checksum(b"a;\nb;\n")


class TestMigrate:
    def test_applies_each_file_once(self, empty_db, migration_dir):
        first = migrations.migrate(empty_db, migration_dir)
        assert [m.filename for m in first] == ["0001_first.sql", "0002_second.sql"]
        assert migrations.migrate(empty_db, migration_dir) == []
        assert set(tables(empty_db)) == {"thing", "schema_migrations"}

    def test_applies_only_new_files(self, empty_db, migration_dir):
        migrations.migrate(empty_db, migration_dir)
        write(migration_dir, "0003_third.sql", "CREATE TABLE other (id int);")
        assert [m.filename for m in migrations.migrate(empty_db, migration_dir)] == [
            "0003_third.sql"
        ]

    def test_refuses_to_run_if_an_applied_migration_was_edited(self, empty_db, migration_dir):
        migrations.migrate(empty_db, migration_dir)
        write(migration_dir, "0001_first.sql", "CREATE TABLE thing (id bigint PRIMARY KEY);")
        write(migration_dir, "0003_third.sql", "CREATE TABLE other (id int);")
        with pytest.raises(
            MigrationError, match=re.escape("0001_first.sql has changed since it was applied")
        ):
            migrations.migrate(empty_db, migration_dir)
        assert "other" not in tables(empty_db)

    def test_refuses_to_run_if_an_applied_migration_is_missing(self, empty_db, migration_dir):
        migrations.migrate(empty_db, migration_dir)
        (migration_dir / "0002_second.sql").unlink()
        with pytest.raises(
            MigrationError, match=re.escape("0002_second.sql has been applied but its file")
        ):
            migrations.migrate(empty_db, migration_dir)

    def test_refuses_to_run_if_an_applied_migration_was_renamed(self, empty_db, migration_dir):
        migrations.migrate(empty_db, migration_dir)
        (migration_dir / "0002_second.sql").rename(migration_dir / "0002_renamed.sql")
        with pytest.raises(MigrationError, match=re.escape("is now 0002_renamed.sql")):
            migrations.migrate(empty_db, migration_dir)

    def test_refuses_a_new_file_numbered_below_an_applied_one(self, empty_db, tmp_path):
        write(tmp_path, "0001_first.sql", "CREATE TABLE a (id int);")
        write(tmp_path, "0003_third.sql", "CREATE TABLE c (id int);")
        migrations.migrate(empty_db, tmp_path)
        write(tmp_path, "0002_late_arrival.sql", "CREATE TABLE b (id int);")
        with pytest.raises(
            MigrationError, match=re.escape("0002_late_arrival.sql is numbered below")
        ):
            migrations.migrate(empty_db, tmp_path)

    def test_a_failed_migration_is_rolled_back_and_left_pending(self, empty_db, migration_dir):
        write(
            migration_dir,
            "0003_broken.sql",
            "CREATE TABLE half_done (id int); SELECT no_such_column FROM thing;",
        )
        with pytest.raises(
            MigrationError, match=re.escape("0003_broken.sql failed and was rolled back")
        ):
            migrations.migrate(empty_db, migration_dir)
        assert "half_done" not in tables(empty_db)
        done, todo = migrations.status(empty_db, migration_dir)
        assert [a.filename for a in done] == ["0001_first.sql", "0002_second.sql"]
        assert [m.filename for m in todo] == ["0003_broken.sql"]

    def test_waits_while_another_migration_holds_the_lock(self, empty_db, migration_dir):
        with psycopg.connect(empty_db, autocommit=True) as other:
            other.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
            waited = []

            def other_finishes() -> None:
                waited.append(True)
                other.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))

            migrations.migrate(empty_db, migration_dir, on_wait=other_finishes)
        assert waited == [True]

    def test_records_what_was_applied_and_by_whom(self, empty_db, migration_dir):
        migrations.migrate(empty_db, migration_dir, role=OWNER_ROLE)
        with psycopg.connect(empty_db) as conn:
            rows = conn.execute(
                "SELECT filename, checksum, applied_by FROM schema_migrations ORDER BY version"
            ).fetchall()
        expected = [
            (m.filename, m.checksum, OWNER_ROLE) for m in migrations.discover(migration_dir)
        ]
        assert rows == expected

    def test_the_real_migrations_apply_as_the_schema_owner(self, empty_db):
        applied = migrations.migrate(empty_db, role=OWNER_ROLE)
        assert applied[0].filename == "0001_initial.sql"
        owners = tables(empty_db)
        assert len(owners) >= 56  # 55 in 0001, plus schema_migrations
        assert set(owners.values()) == {OWNER_ROLE}
