# CoachPlanner working agreement

## Start here

- Read `README.md` for the app architecture and build targets.
- For weekly coaching-planning work, read `Docs/PlanningWorkflow.md` first.
- If it exists, read `PrivatePlanning/SchedulingProfile.md` for local coaching rules. It is deliberately Git-excluded and must never contain contact details, social handles, or message content.

## Guardrails

- Preserve the existing SwiftData schema and local store paths unless a migration is intentionally designed and verified. Supabase is the shared cross-device store; SwiftData is the offline cache and sync remains explicit.
- Treat the Automation tab as the preferred planning interface: snapshot, preview, then apply only after explicit approval.
- Do not send messages, book courts, export financial data, or advance session statuses without explicit user approval.
- A full-week draft replacement is destructive: it replaces coaching sessions but leaves court bookings untouched. Keep the confirmation warning accurate.

## Verification

- Run `git diff --check` after edits.
- Prefer a Mac Catalyst build; also run the iOS Simulator build when the local simulator service is available.
