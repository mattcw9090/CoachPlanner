# CoachPlanner

CoachPlanner is a SwiftUI and SwiftData app for managing weekly coaching sessions, court bookings, students, socials, messaging, finance handoff, and iCalendar exports.

## Project structure

- `CoachPlanner/App/` — app entry point, root navigation, shared styling.
- `CoachPlanner/Models/` — SwiftData models and scheduling enums.
- `CoachPlanner/Features/` — student, session, social, and automation UI grouped by feature.
- `CoachPlanner/Services/` — external handoff and integration helpers.
- `CoachPlanner/Resources/` — app icon, Info.plist, and entitlements.
- `Docs/PlanningWorkflow.md` — the safe snapshot → preview → apply planning workflow.
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

SwiftData keeps an offline local cache on each device. Supabase is the shared cloud database, and cross-device synchronization runs only when **Settings → Sync cloud data** is tapped.

The local store paths and SwiftData schema remain unchanged from the earlier builds, so installing this version over an existing installation keeps the device's current records. The app no longer requests iCloud or remote-notification capabilities.

For routine use, sync before starting work on a device and again after finishing changes. Resolve any reported conflict before editing the same record on another device.
