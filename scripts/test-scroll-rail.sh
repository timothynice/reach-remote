#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-scroll-rail.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc Shared/ScrollRailDynamics.swift Tests/ScrollRailTests/main.swift -o "$TEST_BUILD_DIR/scroll-rail-tests"
"$TEST_BUILD_DIR/scroll-rail-tests"
