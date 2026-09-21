# CoachPlanner

CoachPlanner is a SwiftUI and SwiftData app for managing weekly coaching sessions, court bookings, students, socials, messaging, finance handoff, and iCalendar exports.

## Project structure

- `CoachPlanner/App/` — app entry point, root navigation, shared styling.
- `CoachPlanner/Models/` — SwiftData models and scheduling enums.
- `CoachPlanner/Features/` — student, session, social, and settings UI grouped by feature.
- `CoachPlanner/Services/` — external handoff and integration helpers.
- `CoachPlanner/Resources/` — app icon, Info.plist, and entitlements.
- `Backend/` — Supabase/PostgreSQL schema, migrations, and import utilities.
- `PrivatePlanning/` — local, Git-excluded scheduling rules; never commit personal contact data or message content.

For repository-specific guardrails, see `AGENTS.md`.

## Platforms

- iPhone and iPad on iOS 17 or later
- macOS 14 or later through Mac Catalyst

Both versions use the same models and feature code. The Mac app adds sidebar navigation, desktop-sized editors, side-by-side socials lists, keyboard shortcuts, and right-click alternatives for actions that use swipe gestures on iPhone.

## Run

1. Open `CoachPlanner.xcodeproj` in Xcode.
2. Select the `CoachPlanner` scheme.
3. Choose an iPhone or iPad simulator for iOS, or `My Mac (Mac Catalyst)` for macOS.
4. Build and run.

On Mac, use Command-1 for Students, Command-2 for Sessions, Command-3 for Socials, and Command-comma for Settings. Editors support Command-S to save and Escape to cancel.

## Storage and sync

SwiftData keeps an offline local cache on each device. Supabase is the shared cloud database. **Settings → Automatic sync** uploads saved edits and receives live changes while the app is open. The existing automatic-sync preference is preserved when upgrading. **Sync cloud data** remains available for a full manual reconciliation.

The local store paths and SwiftData schema remain unchanged from the earlier builds, so installing this version over an existing installation keeps the device's current records. The app no longer requests iCloud or remote-notification capabilities.

Changes are saved locally first, then queued durably and grouped briefly before uploading. Supabase Realtime notifications request only affected parent records and their relationships. Startup, reconnect, and occasional foreground recovery perform a complete reconciliation to catch missed notifications. iOS may suspend a background app; reopening it catches up. Offline edits remain queued. Resolve any reported conflict before editing the same record on another device.

**Settings → Cloud sync → Review conflicts** identifies records held back by conflict checks and compares the device and cloud values captured by sync, including individual attendance and payment differences. The review is read-only: opening it does not sync, choose a winner, or overwrite data. Details update through normal sync, stay visible across unrelated updates, and clear only after the affected records are successfully rechecked without conflict. Reports are kept in memory and cleared on sign-out; a new app launch rebuilds them during sync. Conflict resolution and automatic merging are not part of this screen.

For an existing Supabase project, apply `Backend/migrations/2026-09-21_realtime.sql` after the relationship-version migration. This adds the five parent tables to the Realtime publication while retaining existing row-level security. Without it, uploads and foreground recovery still work, but live notifications cannot connect.

Sync overlaps independent downloads within each stage, batches cleanup for deleted records, and only replaces relationships that changed. Downloads are paginated so the server's row limit cannot silently truncate the cache. The `SupabaseSync` log category records each run's duration and request count without logging record contents or credentials.

Run the isolated SwiftData/Supabase regression checks on a Mac with Xcode installed:

```sh
bash Tests/run-supabase-sync-tests.sh
bash Tests/run-realtime-tests.sh
bash Tests/run-auto-sync-tests.sh
python3 -m unittest discover -s Backend/tests -v
```

The sync tests intercept every network request and use an in-memory store and isolated preferences. They cover uploads, downloads, deletions, conflicts, relationship edits, scoped reconciliation, edits during network requests, pagination failures, and request counts without using the installed app's data or Keychain session. Separate tests exercise the live protocol, durable queue, and save notifications.

Local scheduled planning can read a privacy-limited, read-only Supabase snapshot without opening the app through `Tools/coachplanner-cloud snapshot --week next`. One-time Keychain-backed setup is documented in `Backend/README.md`.

## Reusable weekly planning skill

Codex tasks running in this repository can invoke `$coachplanner-weekly-planning`. The repository skill reads the cloud snapshot and the local `PrivatePlanning/SchedulingProfile.md`, checks data freshness, and produces a review-only timetable draft without navigating the app UI or changing any records. Scheduled-task prompts should invoke the skill explicitly so the workflow does not depend on automatic skill selection.
