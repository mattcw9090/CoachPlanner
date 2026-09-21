#!/bin/bash
set -euo pipefail

# Disposable PostgreSQL only. Never accepts a live database URL or credentials.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
pg_bin="${COACHPLANNER_TEST_PG_BIN:-/Library/PostgreSQL/16/bin}"
test_dir="$(mktemp -d /tmp/coachplanner-conflict-sql.XXXXXX)"
trap '"$pg_bin/pg_ctl" -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true' EXIT
"$pg_bin/initdb" -D "$test_dir/data" -A trust --no-locale >"$test_dir/init.log"
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/postgres.log" -o "-k $test_dir -p 55489 -h ''" -w start >/dev/null
cd "$repo_root/Backend"
"$pg_bin/psql" -h "$test_dir" -p 55489 -d postgres -v ON_ERROR_STOP=1 -f tests/conflict_resolution.sql
printf 'Isolated PostgreSQL conflict-resolution tests passed. Logs: %s\n' "$test_dir"
