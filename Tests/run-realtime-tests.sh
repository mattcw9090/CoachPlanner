#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/coachplanner-realtime-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/CoachPlanner/Services/SupabaseRealtimeClient.swift" \
    "$repo_root/Tests/RealtimeTests.swift" -o "$test_directory/realtime-tests"
"$test_directory/realtime-tests"
