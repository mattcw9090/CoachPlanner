#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/coachplanner-social-editing-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$repo_root/CoachPlanner/Models/Student.swift" \
    "$repo_root/CoachPlanner/Models/CoachingSession.swift" \
    "$repo_root/CoachPlanner/Models/SocialSession.swift" \
    "$repo_root/Tests/SocialEditingTests.swift" -o "$test_directory/social-editing-tests"
TZ=Australia/Perth "$test_directory/social-editing-tests"
