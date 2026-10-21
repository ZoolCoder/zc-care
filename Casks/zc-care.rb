cask "zc-care" do
  version "0.2.0"
  sha256 "cffaf3fcac62c2a900c4271c91c927655f1131c063dd1b03e2dc90b9fd0bce86"

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
