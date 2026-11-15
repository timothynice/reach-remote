#!/usr/bin/env bash
# Repeatable local/CI gate. Never installs apps, uploads builds, or posts input.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:---all}"
[[ $# -le 1 && ( "$mode" == --all || "$mode" == --tests-only ) ]] || {
  echo 'usage: scripts/verify.sh [--all|--tests-only]' >&2; exit 2;
}
mkdir -p build/verification
result_dir="$PWD/build/verification"
rm -f "$result_dir/passed.txt"
run_check() {
  local name="$1"; shift
  echo "Checking ${name}…"
  if "$@" > "$result_dir/$name.log" 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name: $result_dir/$name.log" >&2
    tail -n 60 "$result_dir/$name.log" >&2
    return 1
  fi
}
run_check core scripts/test-core.sh
run_check codec scripts/test-codec.sh
run_check viewport scripts/test-viewport.sh
run_check focus scripts/test-focus.sh
run_check displays scripts/test-displays.sh
run_check scroll-rail scripts/test-scroll-rail.sh
run_check scroll-target scripts/test-scroll-target.sh
run_check recovery scripts/test-recovery.sh
run_check auto-connection scripts/test-auto-connection.sh
run_check relay npm --prefix Relay test
run_check relay-carrier scripts/test-relay-carrier.sh
run_check whitespace git diff --check
if [[ "$mode" == --all ]]; then
  run_check project xcodegen generate --quiet --spec project.yml
  run_check mac-release xcodebuild -project Reach.xcodeproj -scheme ReachMac \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/VerificationMac CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
  run_check phone-release xcodebuild -project Reach.xcodeproj -scheme ReachPhone \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/VerificationPhone CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
fi
printf 'Passed %s at %s\n' "$mode" "$(date -u +%FT%TZ)" > "$result_dir/passed.txt"
cat "$result_dir/passed.txt"
echo 'These checks do not establish physical-device usability, internet connectivity, battery life or an independent security audit.'
