#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-tests.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc -swift-version 5 -target $(uname -m)-apple-macosx14.0 Shared/ReachProtocol.swift Shared/DisplayNavigation.swift Shared/ReachSecurity.swift Shared/ReachDestinations.swift Tests/CoreTests/CoreSecurityTests.swift -o "$TEST_BUILD_DIR/security-tests"
"$TEST_BUILD_DIR/security-tests"
swiftc -swift-version 5 -target $(uname -m)-apple-macosx14.0 -D REACH_TESTING Shared/*.swift Tests/Integration/PeerIntegrationTests.swift -o "$TEST_BUILD_DIR/peer-tests"
codesign --force --sign - "$TEST_BUILD_DIR/peer-tests"
"$TEST_BUILD_DIR/peer-tests"
