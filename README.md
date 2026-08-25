# CoachPlanner

CoachPlanner is a SwiftUI and SwiftData app for managing weekly coaching sessions, court bookings, students, socials, messaging, finance handoff, and iCalendar exports.

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

## iCloud Sync

SwiftData uses the private CloudKit database in `iCloud.com.matthewchew.CoachPlanner` for iPhone, iPad, and Mac Catalyst. The CloudKit configuration points at the same `default.store` URL used by the earlier local-only build, so installing an update over the existing iPhone app opens the current records in place. The store remains local and usable offline while CloudKit imports and exports changes when available.

### Xcode Setup

1. Select the `CoachPlanner` target, open **Signing & Capabilities**, and select the same Apple Developer team for iOS and Mac Catalyst.
2. Ensure the **iCloud** capability is present, enable **CloudKit**, and select exactly `iCloud.com.matthewchew.CoachPlanner`.
3. Ensure **Background Modes** is present and **Remote notifications** is checked.
4. Confirm the container exists for the selected team in Certificates, Identifiers & Profiles, then let Xcode refresh the development and distribution provisioning profiles.
5. Confirm both platform variants retain the bundle identifier `com.matthewchew.CoachPlanner`. This project uses one target and one entitlements file, so both variants receive the same CloudKit container.

For the first development deployment, temporarily add `-initializeCloudKitSchema` under **Product > Scheme > Edit Scheme > Run > Arguments Passed On Launch**. Run a Debug build once against the development container, confirm that initialization succeeds, then remove the argument. Before TestFlight or App Store distribution, inspect the record types in CloudKit Console and deploy the development schema to production.

### Existing Data Rollout

1. Back up the iPhone before the first CloudKit-enabled install, and do not uninstall the existing app.
2. Install the updated build over the current iPhone app. In the Xcode console, find the `Persistence` messages and verify `existing=true` plus sensible local record counts.
3. Keep the app open briefly while online and signed into iCloud. Wait for a successful CloudKit `setup` and `export` event.
4. Run the Mac Catalyst app under the same iCloud account and wait for a successful `import` event. Initial synchronization is asynchronous.
5. Verify one create, edit, and delete from iPhone to Mac, then repeat from Mac to iPhone. Keep the original iPhone installation intact until all existing record counts and representative relationships have been checked.
