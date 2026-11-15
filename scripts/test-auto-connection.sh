#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-auto-connect.XXXXXX)
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" Shared/*.swift Tests/Integration/AutoConnectionTests.swift -o "$TEST_BUILD_DIR/auto-tests"
codesign --force --sign - "$TEST_BUILD_DIR/auto-tests"
"$TEST_BUILD_DIR/auto-tests"
