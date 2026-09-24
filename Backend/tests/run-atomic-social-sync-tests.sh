#!/bin/bash
set -euo pipefail

# Disposable PostgreSQL only: no live URL, credentials, or app data accepted.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
pg_bin="${COACHPLANNER_TEST_PG_BIN:-/Library/PostgreSQL/16/bin}"
test_dir="$(mktemp -d /tmp/coachplanner-social-sql.XXXXXX)"
trap '"$pg_bin/pg_ctl" -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true' EXIT
"$pg_bin/initdb" -D "$test_dir/data" -A trust --no-locale >"$test_dir/init.log"
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/postgres.log" -o "-k $test_dir -p 55489 -h ''" -w start >/dev/null
cd "$repo_root/Backend"
"$pg_bin/psql" -h "$test_dir" -p 55489 -d postgres -v ON_ERROR_STOP=1 -f tests/atomic_social_sync.sql
printf 'Isolated PostgreSQL atomic-social-sync tests passed. Logs: %s\n' "$test_dir"
