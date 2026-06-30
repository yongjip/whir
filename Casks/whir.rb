cask "whir" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"   # scripts/notarize.sh prints this

  url "https://github.com/yongjip/whir/releases/download/v#{version}/Whir.dmg"
  name "Whir"
  desc "Local-first AI coding usage & cost monitor for the menu bar"
  homepage "https://github.com/yongjip/whir"

  depends_on macos: ">= :sonoma"

  app "Whir.app"

  zap trash: [
    "~/Library/Application Support/Whir",
    "~/Library/Preferences/com.whir.Whir.plist",
  ]
end
