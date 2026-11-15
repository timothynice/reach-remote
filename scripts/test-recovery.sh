#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-recovery.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc -swift-version 5 -parse-as-library iOS/SessionRecovery.swift Tests/RecoveryTests/main.swift -o "$TEST_BUILD_DIR/recovery-tests"
"$TEST_BUILD_DIR/recovery-tests"
