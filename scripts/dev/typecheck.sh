#!/usr/bin/env bash
# Compiles the whole app (through SIL diagnostics such as definite initialization) against the
# iOS 17 API surface using the Mac Catalyst SDK that ships with the Xcode Command Line Tools —
# handy when Xcode isn't installed. CI does the real iOS build.
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK=$(xcrun --show-sdk-path --sdk macosx)
FW="$SDK/System/iOSSupport/System/Library/Frameworks"
# The explicit -F puts the iOS (Catalyst) ARKit ahead of the macOS one, which has a different API.
# shellcheck disable=SC2046
swiftc -emit-sil -wmo -module-name ScanSpace -o /dev/null -sdk "$SDK" -target arm64-apple-ios17.0-macabi -swift-version 5 \
  -F "$FW" -Xcc -F"$FW" $(find App/Sources -name '*.swift')
