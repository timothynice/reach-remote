#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-displays.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc Shared/ReachProtocol.swift Shared/DisplayNavigation.swift Tests/DisplayTests/main.swift -o "$TEST_BUILD_DIR/display-tests"
"$TEST_BUILD_DIR/display-tests"
