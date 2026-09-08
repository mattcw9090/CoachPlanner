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

## App connection and staged sync

CoachPlanner connects to Supabase from Settings. It uses the project's publishable key, signs in through Supabase Auth, stores only the returned session token in the device Keychain, and displays a cloud snapshot count. SwiftData/CloudKit remains the offline local store while the explicit sync actions reconcile timestamped records with Supabase.

1. Build and run CoachPlanner on the iPhone or Mac Catalyst target.
2. Open **Settings → Supabase Cloud**.
3. Sign in with the Auth user created for the project.
4. Confirm the snapshot counts match the migration verification.
5. Tap **Sync cloud data**. A repeat sync with no further changes should report that cloud data is up to date.

The manual sync updates already-linked students, outsiders, coaching sessions, court bookings, social sessions, and social attendance. Relationship-only tables without `updated_at` conflict metadata (`coaching_session_students`, `social_session_students`, `student_hidden_weeks`, and `social_hidden_people`) remain linked/imported data rather than fully reconciled mutable records. Keep CloudKit enabled until those relationships and create/delete flows have their own verified migration path.
