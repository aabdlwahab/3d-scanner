#!/usr/bin/env bash
# Builds ScanSpace Studio, the macOS companion app, as a universal (Apple silicon + Intel) app,
# ad-hoc signed, and zips it for the install site:
#
#   build/ScanSpace-Studio.zip
#
# The app isn't notarized (that needs a paid Apple Developer account), so the first launch has to
# be confirmed in System Settings › Privacy & Security › Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=${APP_VERSION:-1.0.0}
BUILD=${BUILD_NUMBER:-1}
mkdir -p build
rm -rf build/mac-derived build/ScanSpace-Studio.zip build/release-mac.json
[ -d ScanSpace.xcodeproj ] || xcodegen generate --spec project.yml

beautify() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --renderer github-actions; else cat; fi
}

set +e
xcodebuild build \
  -project ScanSpace.xcodeproj -scheme ScanSpaceStudio -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/mac-derived \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" 2>&1 | tee build/mac.log | beautify
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "::group::Compiler errors"
  grep -E "error:" build/mac.log | sort -u | head -80 || true
  echo "::endgroup::"
  exit "$status"
fi

APP="build/mac-derived/Build/Products/Release/ScanSpace Studio.app"
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/ScanSpace Studio"
ditto -c -k --sequesterRsrc --keepParent "$APP" build/ScanSpace-Studio.zip
cat > build/release-mac.json <<JSON
{"bundleId": "com.scanspace.studio", "version": "$VERSION", "build": "$BUILD", "minOSVersion": "14.0"}
JSON
echo "Built build/ScanSpace-Studio.zip ($(du -h build/ScanSpace-Studio.zip | cut -f1))"
