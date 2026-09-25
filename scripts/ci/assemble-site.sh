#!/usr/bin/env bash
# Assembles the GitHub Pages site in _site/: the install page, IPA downloads, the OTA manifest
# (signed builds) and the AltStore/SideStore source (unsigned build).
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${PAGES_BASE_URL:?Set PAGES_BASE_URL, e.g. https://<user>.github.io/<repo>}"

rm -rf _site
mkdir -p _site/downloads
cp -R site/. _site/
cp build/ScanSpace-unsigned.ipa _site/downloads/
if [ -f build/ScanSpace.ipa ]; then cp build/ScanSpace.ipa _site/downloads/; fi
python3 scripts/ci/site_metadata.py _site
ls -la _site _site/downloads
