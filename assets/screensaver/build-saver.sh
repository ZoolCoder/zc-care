#!/usr/bin/env bash
# Builds WebViewScreenSaver from source and installs it for this user.
# The Homebrew cask is disabled because the release fails Gatekeeper; a local
# build is ad-hoc signed and not quarantined, so macOS loads it.
# Needs Xcode. Usage: assets/screensaver/build-saver.sh
set -euo pipefail

tag=v2.5
repo=https://github.com/liquidx/webviewscreensaver.git
dest="$HOME/Library/Screen Savers"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$repo" "$work/src"
# Xcode 27 rejects the project's 10.13 deployment target; 12.0 is its floor.
xcodebuild -project "$work/src/WebViewScreenSaver/WebViewScreenSaver.xcodeproj" \
  -scheme WebViewScreenSaver -configuration Release archive \
  -archivePath "$work/build.xcarchive" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES MACOSX_DEPLOYMENT_TARGET=12.0 \
  >"$work/build.log" 2>&1 || { grep ' error:' "$work/build.log" >&2; exit 1; }

saver=$(find "$work/build.xcarchive" -name WebViewScreenSaver.saver -type d | head -1)
# The v2.5 tag still says 2.4 in its Info.plist; stamp the tag so the run
# script can tell this build is current, then re-sign the changed bundle.
plutil -replace CFBundleShortVersionString -string "${tag#v}" "$saver/Contents/Info.plist"
codesign --force --sign - "$saver"
mkdir -p "$dest"
rm -rf "$dest/WebViewScreenSaver.saver"
cp -R "$saver" "$dest/"
echo "installed $dest/WebViewScreenSaver.saver ($tag)"
