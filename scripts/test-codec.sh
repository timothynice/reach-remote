#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library Mac/DesktopCapture.swift Tests/CodecTests/main.swift -o .build/tests/reach-codec-tests
.build/tests/reach-codec-tests
