#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-viewport.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc iOS/ViewportGeometry.swift Tests/ViewportTests/main.swift -o "$TEST_BUILD_DIR/viewport-tests"
"$TEST_BUILD_DIR/viewport-tests"
