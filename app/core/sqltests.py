"""Runs the SQL test files in db/tests, each in a brand-new database.

Every file gets a fresh database, migrated as the schema owner, and is then
run with psql, the way the schema was validated. A check prints "PASS: ..."
as a notice; a failed check raises an error starting "FAIL: ...". A file
passes when it prints exactly the number of PASS lines that
expected_passes.toml lists for it, with no errors or warnings. A fixed count
means a check that goes missing is noticed.
"""

import os
import re
import shutil
import subprocess
import tomllib
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app.core import dbtools
from app.core.migrations import migrate
from app.core.paths import COMPOSE_FILE, MIGRATIONS_DIR, SQL_TESTS_DIR

MANIFEST = "expected_passes.toml"

# psql puts "psql:<file>:<line>: " in front of each message from the server.
MESSAGE = re.compile(r"^psql:.*?:\d+: (?P<severity>[A-Z]+):\s+(?P<text>.*)$")

PsqlRunner = Callable[[str, Path], "subprocess.CompletedProcess[str]"]


class SqlTestError(Exception):
    """The SQL tests couldn't be run."""


@dataclass
class FileResult:
    name: str
    expected: int
    passed: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    output: str = ""  # what the file's own queries printed

    @property
    def ok(self) -> bool:
        return not self.problems and len(self.passed) == self.expected


def load_manifest(tests_dir: Path = SQL_TESTS_DIR) -> dict[str, int]:
    """Expected PASS counts by file name, in the order the file lists them."""
    path = tests_dir / MANIFEST
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SqlTestError(f"{path} is missing.") from None
    counts: dict[str, int] = {}
    for name, value in data.items():
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise SqlTestError(f"{MANIFEST}: {name} needs a whole number of expected passes.")
        counts[name] = value
    return counts


def parse_messages(stderr: str) -> tuple[list[str], list[str]]:
    """(passes, problems) from psql's messages. Other notices are ignored."""
    passed: list[str] = []
    problems: list[str] = []
    for line in stderr.splitlines():
        match = MESSAGE.match(line)
        if match is None:
            continue
        severity, text = match["severity"], match["text"]
        if severity == "NOTICE" and text.startswith("PASS: "):
            passed.append(text.removeprefix("PASS: "))
        elif severity in ("WARNING", "ERROR", "FATAL", "PANIC"):
            problems.append(f"{severity}: {text}")
    return passed, problems


def run(
    admin_url: str,
    names: Sequence[str] = (),
    *,
    tests_dir: Path = SQL_TESTS_DIR,
    migrations_dir: Path = MIGRATIONS_DIR,
    on_result: Callable[[FileResult], None] | None = None,
) -> list[FileResult]:
    """Runs the named test files (default: all of them) and returns the results."""
    expected = load_manifest(tests_dir)
    files = {p.name: p for p in tests_dir.glob("*.sql")}
    if unlisted := sorted(files.keys() - expected.keys()):
        raise SqlTestError(
            f"Add {', '.join(unlisted)} to {MANIFEST} with the number of checks it makes."
        )
    if missing := sorted(expected.keys() - files.keys()):
        raise SqlTestError(f"{MANIFEST} lists {', '.join(missing)}, but there's no such file.")
    wanted = [Path(n).name for n in names] or list(expected)
    if unknown := sorted(set(wanted) - files.keys()):
        raise SqlTestError(f"No such SQL test file: {', '.join(unknown)}")

    psql = find_psql(admin_url)
    dbtools.ensure_group_roles(admin_url)
    results = []
    for name in wanted:
        with dbtools.scratch_database(admin_url, "wfm_sqltest") as dbname:
            migrate(
                dbtools.with_database(admin_url, dbname), migrations_dir, role=dbtools.OWNER_ROLE
            )
            completed = psql(dbname, files[name])
        passed, problems = parse_messages(completed.stderr)
        if completed.returncode != 0:
            problems.append(
                f"psql stopped with exit code {completed.returncode}: "
                f"{completed.stderr.strip()[-500:]}"
            )
        result = FileResult(name, expected[name], passed, problems, completed.stdout)
        results.append(result)
        if on_result is not None:
            on_result(result)
    return results


def find_psql(admin_url: str) -> PsqlRunner:
    """A way to run psql: the local one, or else the one inside the Docker Compose database."""
    local = shutil.which("psql")
    if local is not None:
        return lambda dbname, path: _run_local(local, admin_url, dbname, path)
    if _uses_compose_database(admin_url):
        return _run_in_compose
    raise SqlTestError(
        "psql isn't installed. Install the PostgreSQL client (for example "
        "`brew install libpq` or `apt install postgresql-client`), or run the database "
        "with `docker compose up -d db` so the psql inside it can be used."
    )


def _run_local(
    psql: str, admin_url: str, dbname: str, path: Path
) -> "subprocess.CompletedProcess[str]":
    params = conninfo_to_dict(admin_url)
    password = params.pop("password", None)
    params["dbname"] = dbname
    # English message labels whatever the server's locale, so they can be parsed.
    params["options"] = f"{params.get('options', '')} -c lc_messages=C".strip()
    env = dict(os.environ)
    if password is not None:
        env["PGPASSWORD"] = str(password)  # kept off the command line
    return subprocess.run(
        [psql, "-X", "-q", "-d", make_conninfo("", **params), "-f", str(path)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def _run_in_compose(dbname: str, path: Path) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE_FILE), "exec", "-T",
         "-e", "PGOPTIONS=-c lc_messages=C",
         "db", "psql", "-X", "-q", "-U", "postgres", "-d", dbname, "-f", "-"],
        input=path.read_text(encoding="utf-8"),
        capture_output=True,
        text=True,
        check=False,
    )  # fmt: skip


def _uses_compose_database(admin_url: str) -> bool:
    """True if the admin URL points at the Docker Compose database and it's running."""
    params = conninfo_to_dict(admin_url)
    local = params.get("host", "localhost") in ("localhost", "127.0.0.1", "::1")
    if not local or str(params.get("port", "5432")) != "5432" or shutil.which("docker") is None:
        return False
    result = subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE_FILE), "ps", "--status", "running", "--services"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0 and "db" in result.stdout.split()
