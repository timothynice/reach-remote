#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project Reach.xcodeproj -scheme ReachMac -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
xcodebuild -project Reach.xcodeproj -scheme ReachPhone -configuration Debug -derivedDataPath build-ios -destination 'generic/platform=iOS Simulator' build
