#!/usr/bin/env bash
# Builds ZC Care and wraps it in an ad-hoc signed .app: a menu bar app, with no
# Dock icon. Usage: package.sh OUT.app; VERSION sets the bundle version,
# UNIVERSAL=1 builds for both Apple silicon and Intel, as the release does,
# SIGN_IDENTITY signs with a certificate instead, and CLI is the zc-care
# binary the app carries, which the cask puts on PATH.
set -euo pipefail

out=${1:?usage: package.sh OUT.app}
version=${VERSION:-0.0.0-dev}
here=$(cd "$(dirname "$0")" && pwd)
bundle_id=dev.zoolcoder.zccare

# The version lands in XML: refuse anything that is not a plain semver string.
[[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "package.sh: bad VERSION '$version'" >&2; exit 1; }
# CFBundleVersion is numeric and rises with every build; the semver stays in
# CFBundleShortVersionString.
build=${GITHUB_RUN_NUMBER:-$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 1)}

args=(--package-path "$here" -c release)
if [[ ${UNIVERSAL:-} == 1 ]]; then
  args+=(--arch arm64 --arch x86_64)
fi
swift build "${args[@]}"
bin=$(swift build "${args[@]}" --show-bin-path)

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$bin/ZCCare" "$out/Contents/MacOS/ZCCare"
if [[ -n ${CLI:-} ]]; then
  cp "$CLI" "$out/Contents/MacOS/zc-care"
  codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none --options runtime \
    --identifier "$bundle_id.cli" "$out/Contents/MacOS/zc-care"
fi
# The icons icon/make-icon.swift draws from the ZoolCoder mark.
cp "$here"/Resources/AppIcon.icns "$here"/Resources/MenuBarMark.pdf "$out/Contents/Resources/"
cat >"$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ZC Care</string>
    <key>CFBundleDisplayName</key><string>ZC Care</string>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleExecutable</key><string>ZCCare</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${bundle_id}</string>
            <key>CFBundleURLSchemes</key><array><string>zccare</string></array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key><string>ZoolCoder</string>
</dict>
</plist>
PLIST
# Ad-hoc: enough for this Mac, and for the login item to keep its identity.
# macOS ties folder and media permissions to the signature, so an ad-hoc
# build asks again after each rebuild; a certificate keeps them.
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none --options runtime \
  --identifier "$bundle_id" "$out"
# A broken signature fails the build here, not on a user's Mac.
codesign --verify --strict --deep "$out"
echo "built $out ($version, build $build)"
