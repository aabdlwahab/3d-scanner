#!/usr/bin/env bash
# Compiles the platform-independent core (App/Sources/Core) together with the macOS test
# harness in Tests/CoreHarness and runs it. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=Tests/.out
mkdir -p "$OUT"
# shellcheck disable=SC2046
swiftc -O -module-name CoreHarness -target "$(uname -m)-apple-macos14.0" \
  $(find App/Sources/Core -name '*.swift') Tests/CoreHarness/*.swift \
  -o "$OUT/core-harness"
"$OUT/core-harness" "$OUT"
