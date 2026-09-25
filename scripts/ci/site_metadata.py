#!/usr/bin/env python3
"""Writes the install-site metadata next to the IPAs:

  release.json   build info read by index.html
  manifest.plist OTA install manifest (itms-services) for the signed IPA
  apps.json      AltStore / SideStore source for the unsigned IPA
"""
import json
import os
import plistlib
import sys
from datetime import datetime, timezone

site = sys.argv[1]
base = os.environ["PAGES_BASE_URL"].rstrip("/")
repository = os.environ.get("REPOSITORY_URL", "")
commit = os.environ.get("COMMIT_SHA", "")[:7]
owner = os.environ.get("REPO_OWNER", "ScanSpace")
now = datetime.now(timezone.utc)


def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None


unsigned = load("build/release-unsigned.json")
signed = load("build/release-signed.json")
if unsigned is None:
    sys.exit("build/release-unsigned.json is missing — run scripts/ci/build-ipa.sh first")

downloads = os.path.join(site, "downloads")
unsigned_size = os.path.getsize(os.path.join(downloads, "ScanSpace-unsigned.ipa"))
description = (
    "ScanSpace turns an iPhone with LiDAR into a 3D scanner. Capture photo-textured meshes of rooms and "
    "objects, or map a whole apartment room by room with RoomPlan to get a clean 3D model, dimensions and a "
    "floor plan. Export GLB, USDZ, OBJ, PLY, STL, point clouds and PDF floor plans."
)
privacy = {
    "NSCameraUsageDescription": "ScanSpace uses the camera and LiDAR scanner to capture 3D models of rooms, apartments and objects.",
    "NSPhotoLibraryAddUsageDescription": "ScanSpace saves floor plans and renders you choose to export to your photo library.",
}

release = {
    "name": "ScanSpace",
    "version": unsigned["version"],
    "build": unsigned["build"],
    "date": now.isoformat(),
    "commit": commit,
    "repository": repository,
    "minOSVersion": "17.0",
    "unsigned": {"url": "downloads/ScanSpace-unsigned.ipa", "size": unsigned_size, "bundleId": unsigned["bundleId"]},
    "signed": None,
    "source": f"{base}/apps.json",
}

if signed:
    signed_size = os.path.getsize(os.path.join(downloads, "ScanSpace.ipa"))
    release["signed"] = {
        "url": "downloads/ScanSpace.ipa",
        "size": signed_size,
        "bundleId": signed["bundleId"],
        "method": signed["method"],
        "expires": signed.get("expires", ""),
        "manifest": f"{base}/manifest.plist",
    }
    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": f"{base}/downloads/ScanSpace.ipa"},
                    {"kind": "display-image", "url": f"{base}/assets/icon-57.png"},
                    {"kind": "full-size-image", "url": f"{base}/assets/icon-512.png"},
                ],
                "metadata": {
                    "bundle-identifier": signed["bundleId"],
                    "bundle-version": signed["version"],
                    "kind": "software",
                    "title": "ScanSpace",
                },
            }
        ]
    }
    with open(os.path.join(site, "manifest.plist"), "wb") as handle:
        plistlib.dump(manifest, handle)

version_entry = {
    "version": unsigned["version"],
    "buildVersion": unsigned["build"],
    "date": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": f"Build {unsigned['build']} ({commit})",
    "downloadURL": f"{base}/downloads/ScanSpace-unsigned.ipa",
    "size": unsigned_size,
    "minOSVersion": "17.0",
}
source = {
    "name": "ScanSpace",
    "identifier": f"io.github.{owner.lower()}.scanspace.source",
    "subtitle": "LiDAR 3D scanning for iPhone",
    "description": description,
    "iconURL": f"{base}/assets/icon-512.png",
    "website": base,
    "tintColor": "#6B73FF",
    "apps": [
        {
            "name": "ScanSpace",
            "bundleIdentifier": unsigned["bundleId"],
            "developerName": owner,
            "subtitle": "LiDAR 3D scans & floor plans",
            "localizedDescription": description,
            "iconURL": f"{base}/assets/icon-512.png",
            "tintColor": "#6B73FF",
            "category": "utilities",
            "screenshots": [],
            "versions": [version_entry],
            "appPermissions": {"entitlements": [], "privacy": privacy},
            # Legacy fields for older AltStore / SideStore releases.
            "version": version_entry["version"],
            "versionDate": version_entry["date"],
            "versionDescription": version_entry["localizedDescription"],
            "downloadURL": version_entry["downloadURL"],
            "size": unsigned_size,
        }
    ],
    "news": [],
}

with open(os.path.join(site, "apps.json"), "w") as handle:
    json.dump(source, handle, indent=2)
with open(os.path.join(site, "release.json"), "w") as handle:
    json.dump(release, handle, indent=2)
print(json.dumps(release, indent=2))
