# Shortcuts for the `wfm` command and the dev tools. Every target is plain
# `uv run ...` underneath, so everything works without make too.
.DEFAULT_GOAL := help
.PHONY: help check format

help: ## list the commands
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-7s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## everything CI runs: lint, types, migration guard, SQL tests, Python tests
	uv sync --locked
	uv run ruff check .
	uv run ruff format --check .
	uv run mypy
	uv run wfm db check-frozen
	uv run wfm db ensure-server
	uv run wfm db test
	uv run pytest

format: ## tidy the Python code
	uv run ruff format .
	uv run ruff check --fix .
