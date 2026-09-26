#!/usr/bin/env bash
# Builds "ScanSpace Studio.app" with only the Xcode Command Line Tools (no Xcode project needed):
# compiles App/Sources/Core + Mac/Sources into one module, assembles the bundle, and ad-hoc signs it.
# Usage: scripts/dev/build-mac.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=build/mac
APP="$OUT/ScanSpace Studio.app"
VERSION=${APP_VERSION:-1.0.0}
BUILD=${BUILD_NUMBER:-1}
OPT=-O
[ "${1:-}" = "--debug" ] && OPT=-Onone
mkdir -p "$OUT"

# shellcheck disable=SC2046
swiftc $OPT -parse-as-library -module-name ScanSpaceStudio -target "$(uname -m)-apple-macos14.0" \
  $(find App/Sources/Core -name '*.swift') $(find Mac/Sources -name '*.swift') \
  -o "$OUT/ScanSpaceStudio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/ScanSpaceStudio" "$APP/Contents/MacOS/ScanSpace Studio"
sed -e 's/$(EXECUTABLE_NAME)/ScanSpace Studio/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.scanspace.studio/' \
    -e 's/$(PRODUCT_NAME)/ScanSpace Studio/' \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    Mac/Info.plist > "$APP/Contents/Info.plist"
# iconutil wants a folder named *.iconset; the asset catalog's PNGs already use its file names.
rm -rf "$OUT/AppIcon.iconset"
mkdir -p "$OUT/AppIcon.iconset"
cp Mac/Resources/Assets.xcassets/AppIcon.appiconset/*.png "$OUT/AppIcon.iconset/"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
