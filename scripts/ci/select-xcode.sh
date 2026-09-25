#!/usr/bin/env bash
# Selects the newest stable Xcode on the GitHub-hosted macOS runner that has the iOS SDK.
set -euo pipefail

best=""
best_version="0"
for app in /Applications/Xcode*.app; do
  [ -L "$app" ] && continue
  case "$app" in *beta* | *Beta* | *_RC* | *Release_Candidate*) continue ;; esac
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || echo 0)
  [ -d "$app/Contents/Developer/Platforms/iPhoneOS.platform" ] || continue
  if [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" = "$version" ] && [ "$version" != "$best_version" ]; then
    best="$app"
    best_version="$version"
  fi
done

if [ -z "$best" ]; then
  echo "No Xcode with the iOS platform found; keeping the default." >&2
else
  sudo xcode-select -s "$best/Contents/Developer"
fi
xcodebuild -version
xcodebuild -showsdks | grep -i iphoneos || true
