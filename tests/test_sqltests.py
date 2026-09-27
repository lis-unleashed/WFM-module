import re
from pathlib import Path

import pytest

from app.core import sqltests
from app.core.sqltests import SqlTestError, parse_messages

PSQL_OUTPUT = """\
psql:db/tests/x.sql:10: NOTICE:  PASS: first check
psql:db/tests/x.sql:11: NOTICE:  extension "citext" already exists, skipping
psql:<stdin>:12: NOTICE:  PASS: second check
psql:db/tests/x.sql:13: ERROR:  FAIL: third check (statement was accepted)
CONTEXT:  PL/pgSQL function pg_temp_3.expect_fail(text,text,text) line 4 at RAISE
psql:db/tests/x.sql:14: WARNING:  there is no transaction in progress
"""


def test_parse_messages_picks_out_passes_and_problems():
    passed, problems = parse_messages(PSQL_OUTPUT)
    assert passed == ["first check", "second check"]
    assert problems == [
        "ERROR: FAIL: third check (statement was accepted)",
        "WARNING: there is no transaction in progress",
    ]


def check(label: str) -> str:
    return f"DO $$ BEGIN RAISE NOTICE 'PASS: %', '{label}'; END $$;\n"


@pytest.fixture
def dirs(tmp_path: Path) -> tuple[Path, Path]:
    migrations_dir = tmp_path / "migrations"
    tests_dir = tmp_path / "tests"
    migrations_dir.mkdir()
    tests_dir.mkdir()
    (migrations_dir / "0001_first.sql").write_text("CREATE TABLE thing (id int PRIMARY KEY);")
    return migrations_dir, tests_dir


def setup_tests(tests_dir: Path, files: dict[str, str], counts: dict[str, int]) -> None:
    for name, sql in files.items():
        (tests_dir / name).write_text(sql)
    (tests_dir / sqltests.MANIFEST).write_text(
        "".join(f'"{name}" = {count}\n' for name, count in counts.items())
    )


def run(admin_url: str, dirs: tuple[Path, Path]) -> list[sqltests.FileResult]:
    migrations_dir, tests_dir = dirs
    return sqltests.run(admin_url, tests_dir=tests_dir, migrations_dir=migrations_dir)


class TestRun:
    def test_a_file_passes_with_the_expected_number_of_checks(self, admin_url, dirs):
        setup_tests(dirs[1], {"a.sql": check("one") + check("two")}, {"a.sql": 2})
        [result] = run(admin_url, dirs)
        assert result.ok
        assert result.passed == ["one", "two"]

    def test_a_failed_check_fails_the_file(self, admin_url, dirs):
        sql = check("one") + "DO $$ BEGIN RAISE EXCEPTION 'FAIL: two'; END $$;\n" + check("three")
        setup_tests(dirs[1], {"a.sql": sql}, {"a.sql": 3})
        [result] = run(admin_url, dirs)
        assert not result.ok
        assert result.passed == ["one", "three"]
        assert result.problems == ["ERROR: FAIL: two"]

    def test_a_missing_check_fails_the_file(self, admin_url, dirs):
        setup_tests(dirs[1], {"a.sql": check("one")}, {"a.sql": 2})
        [result] = run(admin_url, dirs)
        assert not result.ok
        assert result.problems == []

    def test_each_file_gets_its_own_fresh_migrated_database(self, admin_url, dirs):
        sql = "INSERT INTO thing VALUES (1);\n" + check("inserted")
        setup_tests(dirs[1], {"a.sql": sql, "b.sql": sql}, {"a.sql": 1, "b.sql": 1})
        assert all(r.ok for r in run(admin_url, dirs))

    def test_the_schema_is_owned_by_the_schema_owner(self, admin_url, dirs):
        sql = """
            DO $$ BEGIN
              IF (SELECT tableowner FROM pg_tables WHERE tablename = 'thing') = 'wfm_owner' THEN
                RAISE NOTICE 'PASS: owned by wfm_owner';
              END IF;
            END $$;
        """
        setup_tests(dirs[1], {"a.sql": sql}, {"a.sql": 1})
        assert run(admin_url, dirs)[0].ok

    def test_every_file_must_be_listed_in_the_manifest(self, admin_url, dirs):
        setup_tests(dirs[1], {"a.sql": check("one"), "extra.sql": ""}, {"a.sql": 1})
        with pytest.raises(SqlTestError, match=re.escape("Add extra.sql to expected_passes.toml")):
            run(admin_url, dirs)

    def test_every_listed_file_must_exist(self, admin_url, dirs):
        setup_tests(dirs[1], {"a.sql": check("one")}, {"a.sql": 1, "gone.sql": 4})
        with pytest.raises(
            SqlTestError, match=re.escape("lists gone.sql, but there's no such file")
        ):
            run(admin_url, dirs)


@pytest.mark.parametrize("value", ["0", '"26"', "true", "-1"])
def test_manifest_counts_must_be_positive_whole_numbers(tmp_path, value):
    (tmp_path / sqltests.MANIFEST).write_text(f'"a.sql" = {value}\n')
    with pytest.raises(SqlTestError, match=re.escape("needs a whole number")):
        sqltests.load_manifest(tmp_path)


def test_the_real_manifest_expects_26_passes_from_test_schema():
    assert sqltests.load_manifest()["test_schema.sql"] == 26
