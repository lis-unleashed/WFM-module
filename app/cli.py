"""The `wfm` command. Run `uv run wfm --help` to see what it does."""

import argparse
import subprocess
import sys
from collections.abc import Sequence
from datetime import UTC

import psycopg

from app.core import dbtools, migrations, sqltests
from app.core.settings import ConfigError, Settings


class CommandError(Exception):
    pass


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except (
        CommandError,
        ConfigError,
        dbtools.ServerError,
        migrations.MigrationError,
        sqltests.SqlTestError,
    ) as e:
        print(f"error: {e}", file=sys.stderr)
    except psycopg.OperationalError as e:
        print(f"error: couldn't connect to the database: {e}", file=sys.stderr)
    return 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wfm", description="Unleashed WFM command line.")
    commands = parser.add_subparsers(title="commands", metavar="COMMAND", required=True)

    db = commands.add_parser("db", help="set up, migrate and test the database")
    db_commands = db.add_subparsers(title="database commands", metavar="COMMAND", required=True)

    p = db_commands.add_parser(
        "ensure-server", help="check PostgreSQL is running, and start it with Docker if not"
    )
    p.set_defaults(handler=_ensure_server)

    p = db_commands.add_parser("migrate", help="apply pending migrations")
    p.set_defaults(handler=_migrate)

    p = db_commands.add_parser("status", help="list applied and pending migrations")
    p.set_defaults(handler=_status)

    p = db_commands.add_parser("test", help="run the SQL tests, each in a brand-new database")
    p.add_argument("files", nargs="*", help="test files to run (default: all of them)")
    p.add_argument(
        "-v", "--verbose", action="store_true", help="also show what the tests' queries print"
    )
    p.set_defaults(handler=_test)

    p = db_commands.add_parser(
        "check-frozen", help="fail if a migration that's already on main has been edited"
    )
    p.add_argument(
        "--against",
        default="origin/main",
        metavar="REF",
        help="the branch to compare with (default: origin/main)",
    )
    p.set_defaults(handler=_check_frozen)
    return parser


def _ensure_server(args: argparse.Namespace) -> int:
    url = Settings().require_admin_database_url()
    dbtools.ensure_server(url, on_start=lambda: print("Starting PostgreSQL 16 with Docker Compose"))
    print(f"PostgreSQL is running at {dbtools.describe(url)}.")
    return 0


def _migrate(args: argparse.Namespace) -> int:
    url = Settings().require_migration_database_url()
    print(f"Migrating {dbtools.describe(url)}")
    done = migrations.migrate(
        url,
        on_applied=lambda m, seconds: print(f"  applied {m.filename} ({seconds:.1f}s)"),
        on_wait=lambda: print("  waiting for another migration to finish"),
    )
    print(f"Applied {_plural(len(done), 'migration')}." if done else "Already up to date.")
    return 0


def _status(args: argparse.Namespace) -> int:
    url = Settings().require_migration_database_url()
    done, todo = migrations.status(url)
    print(f"{dbtools.describe(url)}: {len(done)} applied, {len(todo)} pending")
    for a in done:
        print(f"  applied  {a.filename}  {a.applied_at.astimezone(UTC):%d %b %Y %H:%M} UTC")
    for m in todo:
        print(f"  pending  {m.filename}")
    return 0


def _test(args: argparse.Namespace) -> int:
    url = Settings().require_admin_database_url()
    width = max(len(name) for name in sqltests.load_manifest())

    def show(result: sqltests.FileResult) -> None:
        count = f"{len(result.passed)}/{result.expected} PASS"
        verdict = "" if result.ok else "  <- FAILED"
        print(f"{result.name.ljust(width, '.')}.. {count}{verdict}")
        if len(result.passed) > result.expected and not result.problems:
            print(f"    more checks than expected: raise the count in {sqltests.MANIFEST}")
        for problem in result.problems:
            print(f"    {problem}")
        if args.verbose and result.output.strip():
            print("\n".join(f"    | {line}" for line in result.output.rstrip().splitlines()))

    results = sqltests.run(url, args.files, on_result=show)
    failed = [r for r in results if not r.ok]
    checks = sum(len(r.passed) for r in results)
    if failed:
        print(f"{len(failed)} of {_plural(len(results), 'SQL test file')} failed.")
        return 1
    print(f"All {_plural(len(results), 'SQL test file')} passed ({checks} checks).")
    return 0


def _check_frozen(args: argparse.Namespace) -> int:
    try:
        edited = migrations.edited_since(args.against)
    except subprocess.CalledProcessError as e:
        raise CommandError(
            f"couldn't compare with {args.against} ({e.stderr.strip()}). "
            "Fetch it first, for example: git fetch origin main"
        ) from e
    if not edited:
        print(f"No migration that's on {args.against} has been edited.")
        return 0
    for status, path in edited:
        print(f"  {path} was {status}", file=sys.stderr)
    print(
        f"Migrations on {args.against} can't be edited. Undo the edits above "
        "and make the change in a new migration instead.",
        file=sys.stderr,
    )
    return 1


def _plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"
