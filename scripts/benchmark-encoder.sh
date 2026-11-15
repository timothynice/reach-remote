#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/tests
xcrun swiftc -O -swift-version 5 -parse-as-library Mac/DesktopCapture.swift Tests/PerformanceTests/main.swift -o .build/tests/reach-encoder-benchmark
.build/tests/reach-encoder-benchmark "${1:-15}"
