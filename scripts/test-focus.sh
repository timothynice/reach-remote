#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -parse-as-library Shared/ReachProtocol.swift Shared/DisplayNavigation.swift Mac/DesktopFocus.swift Tests/FocusTests/main.swift -o .build/tests/reach-focus-tests
.build/tests/reach-focus-tests
