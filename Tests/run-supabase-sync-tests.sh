#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/coachplanner-sync-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Compile the harness in the service's file scope to exercise private sync paths
# without exposing them to the app or accessing its Keychain and persistent store.
/usr/bin/ruby -e 'File.write(ARGV[0], ARGV.drop(1).map { |path| File.read(path) }.join("\n"))' \
    "$test_directory/SyncTests.swift" \
    "$repo_root/CoachPlanner/Services/SupabaseCloud.swift" \
    "$repo_root/Tests/SupabaseSyncTests.swift"
xcrun swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/CoachPlanner/Models/Student.swift" \
    "$repo_root/CoachPlanner/Models/CoachingSession.swift" \
    "$repo_root/CoachPlanner/Models/SocialSession.swift" \
    "$test_directory/SyncTests.swift" -o "$test_directory/sync-tests"
TZ=Australia/Perth "$test_directory/sync-tests"
