#!/bin/sh
# Update the checked-in cask from a built release archive.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-${VERSION:-$(sed -n '1p' VERSION)}}
ZIP_PATH=${2:-dist/SibDocks-$VERSION.zip}
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

mkdir -p Casks
cat > Casks/sibdocks.rb <<RUBY
cask "sibdocks" do
  version "$VERSION"
  sha256 "$SHA256"

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
RUBY

printf 'updated Casks/sibdocks.rb for %s (%s)\n' "$VERSION" "$SHA256"
