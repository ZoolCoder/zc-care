#!/usr/bin/env bash
# Prints the Homebrew cask for ZC Care. The release workflow runs it after it
# uploads the zip, and opens a pull request with the result as Casks/zc-care.rb.
# The app carries zc-care, so this cask also links it onto PATH.
# Usage: cask.sh VERSION SHA256
set -euo pipefail

version=${1:?usage: cask.sh VERSION SHA256}
sha=${2:?usage: cask.sh VERSION SHA256}

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

  uninstall quit: "dev.zoolcoder.zccare"

  zap trash: [
    "~/Library/Application Support/ZCCare",
    "~/Library/Application Support/dev.zoolcoder.zccare",
    "~/Library/Caches/dev.zoolcoder.zccare",
    "~/Library/Logs/ZCCare",
    "~/Library/Preferences/dev.zoolcoder.zccare.plist",
  ]

  caveats <<~EOS
    ZC Care is signed ad hoc until it is notarised, so macOS blocks the first
    start. Open it once from Finder with Control-click, Open, or run:
      xattr -dr com.apple.quarantine "#{appdir}/ZCCare.app"
  EOS
end
CASK
