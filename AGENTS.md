# CoachPlanner working agreement

## Start here

- Read `README.md` for the app architecture and build targets.
- If it exists, read `PrivatePlanning/SchedulingProfile.md` for local coaching rules. It is deliberately Git-excluded and must never contain contact details, social handles, or message content.

## Guardrails

- Preserve the existing SwiftData schema and local store paths unless a migration is intentionally designed and verified. Supabase is the shared cross-device store; SwiftData is the offline cache and sync remains explicit.
- Do not send messages, book courts, export financial data, or advance session statuses without explicit user approval.

## Verification

- Run `git diff --check` after edits.
- Prefer a Mac Catalyst build; also run the iOS Simulator build when the local simulator service is available.
