#!/usr/bin/env bash
# Prints the Homebrew cask for ZC Care. The release workflow runs it after it
# uploads the zip, and opens a pull request with the result as Casks/zc-care.rb.
# The app carries zc-care, so this cask also links it onto PATH.
# Usage: cask.sh VERSION SHA256
set -euo pipefail

version=${1:?usage: cask.sh VERSION SHA256}
sha=${2:?usage: cask.sh VERSION SHA256}
# Both land in Ruby source: refuse anything but a plain version and a hex digest.
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cask.sh: bad VERSION '$version'" >&2; exit 1; }
[[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "cask.sh: bad SHA256" >&2; exit 1; }

cat <<CASK
cask "zc-care" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/zoolcoder/zc-care/releases/download/v#{version}/ZCCare_#{version}.zip"
  name "ZC Care"
  desc "Set up a Mac from one config, keep it that way, and keep it clean"
  homepage "https://zoolcoder.github.io/zc-care/"

  depends_on macos: ">= :sonoma"

  app "ZCCare.app"
  binary "#{appdir}/ZCCare.app/Contents/MacOS/zc-care"

  # INTERIM until a Developer ID release: the app is signed ad hoc, so the
  # quarantine flag brew's download sets makes Gatekeeper kill the CLI (exit
  # 137). Clear it. Remove this block once the app is signed and notarised.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ZCCare.app"]
  end

  uninstall quit: "dev.zoolcoder.zccare"

  zap trash: [
    "~/Library/Application Support/ZCCare",
    "~/Library/Application Support/dev.zoolcoder.zccare",
    "~/Library/Caches/dev.zoolcoder.zccare",
    "~/Library/Logs/ZCCare",
    "~/Library/Preferences/dev.zoolcoder.zccare.plist",
  ]

  caveats <<~EOS
    ZC Care is signed ad hoc until a Developer ID release, so it is not
    notarised. This cask clears the quarantine flag when it installs. If macOS
    still blocks the first start, Control-click the app and choose Open, or run:
      xattr -dr com.apple.quarantine "#{appdir}/ZCCare.app"
  EOS
end
CASK
