# CoachPlanner backend contract

This directory defines the first cloud-backed storage contract. It is provider-neutral PostgreSQL plus HTTP/JSON, so it can later be hosted on Supabase, Neon + an API service, or another managed Postgres provider.

## Design decisions

- The server is the authoritative source of truth.
- The iPhone and Mac keep SwiftData as an offline cache during the migration.
- Every mutable row has a UUID, `updated_at`, and a soft-delete timestamp.
- Client writes include an `expected_updated_at` value. A stale write returns `409 Conflict` instead of silently overwriting another device.
- Contact details are private fields and must only be returned to an authenticated coach account.

## Files

- `schema.sql` — PostgreSQL tables, indexes, and updated-timestamp trigger.
- `migrations/2026-09-08_relationship_versions.sql` — idempotent parent-version triggers for relationship sync on an existing project.
- `migrations/2026-09-21_realtime.sql` — idempotently publishes the five parent tables for authenticated live notifications.
- `migrations/2026-09-21_conflict_resolution.sql` — atomic, explicitly reviewed conflict choices; apply after the schema and owner-scoped policies. Required before the app can apply a conflict choice.
- `openapi.yaml` — the minimum API contract for storage migration and synchronization.
- `export_swiftdata_store.py` — read-only exporter for the existing Mac SwiftData store.
- `import_bundle.py` — authenticated, idempotent uploader for an exported bundle.
- `coachplanner_cloud.py` — read-only Supabase command used by local planning automation.
- `coachplanner_cloud_config.json` — tracked non-secret project URL, publishable key, and workspace ID for that command.
- `SupabaseSetup.md` — provider-specific setup and secret-handling checklist.
- `supabase_policies.sql` — owner-scoped Row Level Security policies.

## Read planning data without opening the app

The local automation command reads the authenticated Supabase workspace directly. It has no database write commands and deliberately excludes contact details, fees, and session descriptions.

Sign in once; the password is entered invisibly and is never stored. The short Supabase refresh token is kept in a CLI-specific macOS Keychain entry, separate from the iPhone and Mac app sessions. Access tokens exist only in memory while a command runs:

```sh
Tools/coachplanner-cloud auth login --email YOUR_SUPABASE_EMAIL
```

Check access and request the next Monday-Sunday planning snapshot:

```sh
Tools/coachplanner-cloud auth status
Tools/coachplanner-cloud snapshot --week next
```

Use `--week current` or an explicit Monday such as `--week 2026-09-14` when needed. Add `--output /private/tmp/coachplanner-snapshot.json` to keep the full JSON in an owner-readable file instead of standard output.

The output includes the prior-week baseline, target-week sessions, court bookings, student demand, week-specific hiding, and calculated underallocation. App changes appear only after a successful device sync. Current builds upload saved changes automatically while open and connected; older builds or devices with automatic sync disabled need **Sync cloud data**. Offline edits are not yet visible to planning.

## Export the existing Mac store

First create a workspace UUID for the future backend. Then run the exporter against a copy or the live store while CoachPlanner is closed:

```sh
python3 Backend/export_swiftdata_store.py \
  --store "/Users/matthewchew/Library/Application Support/CoachPlanner/CoachPlanner.store" \
  --output /private/tmp/coachplanner-import.json \
  --workspace-id 00000000-0000-0000-0000-000000000001
```

The exporter opens SQLite in read-only mode, preserves relationships using stable migration UUIDs, validates relationship references, and writes a JSON bundle. It never alters the SwiftData store. Do not upload the resulting file to a public location because it contains contact details.

## Upload a bundle

After the backend is deployed, test request construction first:

```sh
python3 Backend/import_bundle.py \
  --bundle /private/tmp/coachplanner-import.json \
  --base-url https://your-api.example.com/v1 \
  --dry-run
```

For the real upload, set the task-specific `COACHPLANNER_API_TOKEN` environment variable and omit `--dry-run`. The client sends an idempotency key derived from the bundle, so a retry is safe if the network times out.

The app uses this contract for automatic saved-edit uploads, live updates, and full recovery through **Sync cloud data** while SwiftData remains its offline cache. Live notifications are hints to fetch authoritative records, not a replacement for reconciliation, conflict checks, or the deletion ledger.

## Apply a reviewed conflict choice

Deploy `migrations/2026-09-21_conflict_resolution.sql` with the project's database owner after `schema.sql` and `supabase_policies.sql`. It is a separate migration, not automatically installed by `schema.sql`. The `resolve_coachplanner_conflict` RPC runs with the caller's ordinary authenticated RLS permissions; it is not a service-role bypass.

The app submits the exact reviewed parent and complete child snapshot. The RPC locks and compares them before applying one explicit device or cloud choice. Device replacement updates the parent and its relationships in one transaction; an error rolls everything back. Cloud choice only validates and returns the current snapshot. A stale snapshot returns `CP_CONFLICT_STALE`; the user must review again. Person deletion additionally requires reviewing incoming session and attendance relationships, because removing the person also removes those links. Never replace this RPC with sequential REST writes when the migration is unavailable.

Run the isolated SQL checks without touching a live project:

```sh
bash Backend/tests/run-conflict-resolution-tests.sh
```

The runner creates its own temporary PostgreSQL cluster, with mock authentication and owner-scoped RLS. Set `COACHPLANNER_TEST_PG_BIN` only if the PostgreSQL binaries are elsewhere. No cloud credentials or database URL are accepted.
