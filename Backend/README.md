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

The output includes the prior-week baseline, target-week sessions, court bookings, student demand, week-specific hiding, and calculated underallocation. It also states that app changes remain absent until **Sync cloud data** is tapped on the device where those changes were made.

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

The app uses this contract through an explicit **Sync cloud data** action while SwiftData remains its offline cache. Supabase is the shared cross-device store; synchronization is intentionally manual.
