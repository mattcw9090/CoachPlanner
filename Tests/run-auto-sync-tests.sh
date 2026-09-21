#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/coachplanner-auto-sync-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Reuse the established REST mock, omitting that suite's separate @main runner.
# Concatenation grants the harness access to private state without app hooks.
/usr/bin/ruby -e '
  output, cloud, coordinator, mock_source, harness = ARGV
  source = File.read(mock_source)
  marker = "@main\nprivate struct SupabaseSyncTests"
  abort "Sync mock entry point changed" unless source.include?(marker)
  File.write(output, [File.read(cloud), File.read(coordinator), source.split(marker, 2).first, File.read(harness)].join("\n"))
' "$test_directory/AutoSyncTests.swift" \
    "$repo_root/CoachPlanner/Services/SupabaseCloud.swift" \
    "$repo_root/CoachPlanner/Services/SupabaseAutoSync.swift" \
    "$repo_root/Tests/SupabaseSyncTests.swift" \
    "$repo_root/Tests/AutoSyncTests.swift"

xcrun swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/CoachPlanner/Models/Student.swift" \
    "$repo_root/CoachPlanner/Models/CoachingSession.swift" \
    "$repo_root/CoachPlanner/Models/SocialSession.swift" \
    "$repo_root/CoachPlanner/Services/CloudSyncScope.swift" \
    "$repo_root/CoachPlanner/Services/SupabaseRealtimeClient.swift" \
    "$test_directory/AutoSyncTests.swift" -o "$test_directory/auto-sync-tests"
TZ=Australia/Perth "$test_directory/auto-sync-tests"
