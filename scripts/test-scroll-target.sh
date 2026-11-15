#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library Shared/*.swift Mac/DesktopScrollTarget.swift Tests/ScrollTargetTests/main.swift -o .build/tests/reach-scroll-target-tests
.build/tests/reach-scroll-target-tests
