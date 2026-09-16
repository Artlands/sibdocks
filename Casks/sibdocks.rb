cask "sibdocks" do
  version "0.1.0"
  sha256 "5f28e5d35169e1a53256dedca6fe5364b58155b9c9d04e7cb16d8061242404ba"

  url "https://github.com/Artlands/sibdocks/releases/download/v#{version}/SibDocks-#{version}.zip"
  name "SibDocks"
  desc "Per-display window dock for macOS"
  homepage "https://github.com/Artlands/sibdocks"

  livecheck do
    url "https://github.com/Artlands/sibdocks"
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "SibDocks.app"

  caveats do
    <<~EOS
      SibDocks needs Accessibility access to enumerate and control windows.
      Enable it in System Settings → Privacy & Security → Accessibility.
    EOS
  end

  zap trash: [
    "~/Library/Preferences/com.artlands.sibdocks.plist",
    "~/Library/Saved Application State/com.artlands.sibdocks.savedState",
  ]
end
