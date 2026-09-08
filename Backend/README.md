# CoachPlanner backend contract

This directory defines the first cloud-backed storage contract. It is provider-neutral PostgreSQL plus HTTP/JSON, so it can later be hosted on Supabase, Neon + an API service, or another managed Postgres provider.

## Design decisions

- The server is the authoritative source of truth.
- The iPhone and Mac keep SwiftData as an offline cache during the migration.
- Every mutable row has a UUID, `updated_at`, and a soft-delete timestamp.
- Client writes include an `expected_updated_at` value. A stale write returns `409 Conflict` instead of silently overwriting another device.
- Contact details are private fields and must only be returned to an authenticated coach account.
- Scheduling snapshot and draft-preview endpoints are read/validation operations; applying a draft remains an explicit write.

## Files

- `schema.sql` — PostgreSQL tables, indexes, and updated-timestamp trigger.
- `migrations/2026-09-08_relationship_versions.sql` — idempotent parent-version triggers for relationship sync on an existing project.
- `openapi.yaml` — the minimum API contract needed by the planner and app migration.
- `export_swiftdata_store.py` — read-only exporter for the existing Mac SwiftData store.
- `import_bundle.py` — authenticated, idempotent uploader for an exported bundle.
- `SupabaseSetup.md` — provider-specific setup and secret-handling checklist.
- `supabase_policies.sql` — owner-scoped Row Level Security policies.

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

The app currently uses this contract through an explicit **Sync cloud data** action while SwiftData remains its offline cache. CloudKit stays enabled during the two-device migration check and should only be retired after create, relationship-edit, and delete propagation are verified.
