cask "zc-care" do
  version "0.4.0"
  sha256 "1493161c3ed408e54d2586720dab8313835a2bdb7e6be281197a5280d76312fa"

  url "https://github.com/zoolcoder/zc-care/releases/download/v#{version}/ZCCare_#{version}.zip"
  name "ZC Care"
  desc "Set up a machine from one config, keep it that way, and keep it clean"
  homepage "https://zoolcoder.github.io/zc-care/"

  depends_on macos: :sonoma

  app "ZCCare.app"
  binary "#{appdir}/ZCCare.app/Contents/MacOS/zc-care"

  # INTERIM until a Developer ID release: the app is signed ad hoc, so the
  # quarantine flag brew's download sets makes Gatekeeper kill the CLI (exit
  # 137). Clear it. Remove this block once the app is signed and notarised.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/ZCCare.app"],
        writable_paths: ["ZCCare.app"], writable_base: :appdir
  end

  uninstall quit: "dev.zoolcoder.zccare"

  zap trash: [
    "~/Library/Application Support/dev.zoolcoder.zccare",
    "~/Library/Application Support/ZCCare",
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
