#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD_DIR=$(mktemp -d /tmp/reach-relay-test.XXXXXX)
RELAY_PID=''
cleanup() {
  if [[ -n "$RELAY_PID" ]]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf "$TEST_BUILD_DIR"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_BUILD_DIR/key.pem" -out "$TEST_BUILD_DIR/cert.pem" -days 1 -subj /CN=localhost > "$TEST_BUILD_DIR/openssl.log" 2>&1
openssl x509 -in "$TEST_BUILD_DIR/cert.pem" -outform DER -out "$TEST_BUILD_DIR/cert.der"
node Relay/test-tls-server.mjs "$TEST_BUILD_DIR/key.pem" "$TEST_BUILD_DIR/cert.pem" > "$TEST_BUILD_DIR/port" 2> "$TEST_BUILD_DIR/server.log" &
RELAY_PID=$!
for attempt in {1..50}; do
  [[ -s "$TEST_BUILD_DIR/port" ]] && break
  sleep 0.1
done
[[ -s "$TEST_BUILD_DIR/port" ]] || { cat "$TEST_BUILD_DIR/server.log"; exit 1; }
swiftc -swift-version 5 -D REACH_TESTING -target "$(uname -m)-apple-macosx14.0" Shared/*.swift Tests/Integration/RelayCarrierTests.swift -o "$TEST_BUILD_DIR/relay-tests"
codesign --force --sign - "$TEST_BUILD_DIR/relay-tests"
"$TEST_BUILD_DIR/relay-tests" "$(cat "$TEST_BUILD_DIR/port")" "$TEST_BUILD_DIR/cert.der"
