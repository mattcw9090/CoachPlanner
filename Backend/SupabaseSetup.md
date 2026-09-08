# Supabase setup for CoachPlanner

This is the provider-specific handoff for the cloud migration. It does not contain secrets.

## Create the project

1. Create a private Supabase project at [supabase.com](https://supabase.com/).
2. Choose a strong database password and keep it in a password manager.
3. In **SQL Editor**, run [`schema.sql`](./schema.sql).
4. In **Authentication**, create the single CoachPlanner user account. The user ID will become `workspaces.owner_user_id`.
5. Create one workspace row using that user ID:

```sql
insert into workspaces (owner_user_id, name)
values ('YOUR_AUTH_USER_UUID', 'CoachPlanner')
returning id;
```

6. Keep the returned workspace UUID. It should be passed to the exporter as `--workspace-id`.

## Values needed for the next implementation step

From **Project Settings → API**, the app/backend integration will need:

- Project URL, for example `https://your-project.supabase.co`.
- The publishable/anon key for the iPhone and Mac app.
- A user access token for the one-time importer, generated after signing in to the CoachPlanner account.

Never put the `service_role` key in the iPhone app, repository, migration bundle, or shell history. It is only appropriate for a server-side importer/function.

## Migration order

1. Run the SQL schema.
2. Create the authenticated user and workspace.
3. Export the Mac store with `export_swiftdata_store.py` using the workspace UUID.
4. Deploy the authenticated `/import` function/API.
5. Run `import_bundle.py --dry-run` first, then perform the real upload.
6. Compare row counts before changing the app to read from the API.

## App connection and manual sync

CoachPlanner connects to Supabase from Settings. It uses the project's publishable key, signs in through Supabase Auth, stores only the returned session token in the device Keychain, and displays a cloud snapshot count. SwiftData remains the offline local cache while the explicit sync action reconciles timestamped records with Supabase.

1. Build and run CoachPlanner on the iPhone or Mac Catalyst target.
2. Open **Settings → Supabase Cloud**.
3. Sign in with the Auth user created for the project.
4. Confirm the snapshot counts match the migration verification.
5. Tap **Sync cloud data**. A repeat sync with no further changes should report that cloud data is up to date.

Before installing the create/delete and relationship-sync build over an existing Supabase project, run [`migrations/2026-09-08_relationship_versions.sql`](./migrations/2026-09-08_relationship_versions.sql) once in the SQL Editor. It is safe to run repeatedly. The triggers advance the parent record's version when only a student list, hidden week, hidden person, or attendance changes.

The manual sync now creates, updates, downloads, and soft-deletes students, outsiders, coaching sessions, court bookings, and social sessions. It also reconciles coaching/social student lists, student hidden weeks, social hidden people, and social attendance. The first successful run establishes a local deletion baseline; later missing records can then be distinguished from records newly created on another device.

Supabase is the shared cross-device store. Sync before starting work on a device and after finishing changes; the app does not synchronize in the background.
