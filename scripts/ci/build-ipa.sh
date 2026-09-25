#!/usr/bin/env bash
# Builds the IPAs published on the GitHub Pages install site:
#
#   build/ScanSpace-unsigned.ipa   always — SideStore / AltStore / Sideloadly re-sign it with your Apple ID
#   build/ScanSpace.ipa            only when signing secrets are set — one-tap install from Safari
#
# Signing (optional) uses these environment variables (GitHub Actions secrets):
#   IOS_CERTIFICATE_P12       base64 of an "Apple Distribution" (or "Apple Development") .p12
#   IOS_CERTIFICATE_PASSWORD  password of that .p12
#   IOS_PROVISIONING_PROFILE  base64 of an Ad Hoc (or Development / Enterprise) .mobileprovision
# The bundle identifier and team are read from the provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=${APP_VERSION:-1.0.0}
BUILD=${BUILD_NUMBER:-1}
DEFAULT_BUNDLE_ID=com.scanspace.app
TMP=${RUNNER_TEMP:-$(mktemp -d)}
mkdir -p build
rm -rf build/*.ipa build/*.xcarchive build/Payload build/signed build/release-*.json

xcodegen generate --spec project.yml

beautify() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --renderer github-actions; else cat; fi
}

archive() { # archive <path> [extra build settings...]
  local path=$1
  shift
  local log="build/$(basename "$path" .xcarchive).log"
  set +e
  xcodebuild archive \
    -project ScanSpace.xcodeproj -scheme ScanSpace -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$path" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "$@" 2>&1 | tee "$log" | beautify
  local status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ] && grep -q "is not installed. To use with Xcode, first download and install the platform" "$log"; then
    echo "iOS platform missing — downloading it and retrying"
    xcodebuild -downloadPlatform iOS
    xcodebuild archive \
      -project ScanSpace.xcodeproj -scheme ScanSpace -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$path" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" "$@" 2>&1 | tee "$log" | beautify
    status=${PIPESTATUS[0]}
  fi
  if [ "$status" -ne 0 ]; then
    echo "::group::Compiler errors"
    grep -E "error:|warning: .*(deprecated|unavailable)" "$log" | sort -u | head -80 || true
    echo "::endgroup::"
    return "$status"
  fi
}

# --- 1. Unsigned build -------------------------------------------------------------------------
archive build/unsigned.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  PRODUCT_BUNDLE_IDENTIFIER="$DEFAULT_BUNDLE_ID"
mkdir -p build/Payload
cp -R build/unsigned.xcarchive/Products/Applications/ScanSpace.app build/Payload/
(cd build && zip -qry ScanSpace-unsigned.ipa Payload && rm -rf Payload)
echo "Built build/ScanSpace-unsigned.ipa ($(du -h build/ScanSpace-unsigned.ipa | cut -f1))"

cat > build/release-unsigned.json <<EOF
{"bundleId": "$DEFAULT_BUNDLE_ID", "version": "$VERSION", "build": "$BUILD"}
EOF

# --- 2. Signed build (optional) ----------------------------------------------------------------
if [ -z "${IOS_CERTIFICATE_P12:-}" ] || [ -z "${IOS_PROVISIONING_PROFILE:-}" ]; then
  echo "No signing secrets configured — skipping the signed (one-tap install) build."
  exit 0
fi

KEYCHAIN="$TMP/scanspace-signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 16)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
echo "$IOS_CERTIFICATE_P12" | base64 --decode > "$TMP/certificate.p12"
security import "$TMP/certificate.p12" -k "$KEYCHAIN" -P "${IOS_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "::error::No code signing identity found in IOS_CERTIFICATE_P12"; exit 1; }

PROFILE="$TMP/profile.mobileprovision"
echo "$IOS_PROVISIONING_PROFILE" | base64 --decode > "$PROFILE"
security cms -D -i "$PROFILE" > "$TMP/profile.plist"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$TMP/profile.plist" 2>/dev/null; }
PROFILE_UUID=$(plist UUID)
PROFILE_NAME=$(plist Name)
TEAM_ID=$(plist TeamIdentifier:0)
APP_ID=$(plist Entitlements:application-identifier)
BUNDLE_ID=${APP_ID#*.}
case "$BUNDLE_ID" in
  "*") BUNDLE_ID=$DEFAULT_BUNDLE_ID ;;
  *"*") BUNDLE_ID="${BUNDLE_ID%\*}scanspace" ;;
esac
if plist ProvisionsAllDevices >/dev/null; then
  METHOD=enterprise LEGACY_METHOD=enterprise
elif [ "$(plist Entitlements:get-task-allow)" = "true" ]; then
  METHOD=debugging LEGACY_METHOD=development
else
  METHOD=release-testing LEGACY_METHOD=ad-hoc
fi
for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$PROFILE" "$dir/$PROFILE_UUID.mobileprovision"
done
echo "Signing as '$IDENTITY' with profile '$PROFILE_NAME' ($LEGACY_METHOD) for $BUNDLE_ID"

archive build/signed.xcarchive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_IDENTITY="$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN"

export_ipa() { # export_ipa <method>
  cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$1</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_UUID</string></dict>
  <key>compileBitcode</key><false/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
EOF
  rm -rf build/signed
  xcodebuild -exportArchive -archivePath build/signed.xcarchive -exportPath build/signed \
    -exportOptionsPlist build/ExportOptions.plist 2>&1 | beautify
  return "${PIPESTATUS[0]}"
}
export_ipa "$METHOD" || export_ipa "$LEGACY_METHOD"
mv build/signed/*.ipa build/ScanSpace.ipa
echo "Built build/ScanSpace.ipa ($(du -h build/ScanSpace.ipa | cut -f1))"

cat > build/release-signed.json <<EOF
{"bundleId": "$BUNDLE_ID", "version": "$VERSION", "build": "$BUILD", "method": "$LEGACY_METHOD", "team": "$TEAM_ID",
 "expires": "$(plist ExpirationDate)"}
EOF
security delete-keychain "$KEYCHAIN" || true
