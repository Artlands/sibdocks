#!/bin/sh
# Builds SibDocks.app. Run ./build.sh && open SibDocks.app
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(sed -n '1p' VERSION)}
BUILD_NUMBER=${BUILD_NUMBER:-1}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.artlands.sibdocks}
APP=${APP_PATH:-SibDocks.app}
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
RESET_TCC=${RESET_TCC:-1}

swift Scripts/render_menu_icon.swift Assets/AppIcon.icns
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SibDocks "$APP/Contents/MacOS/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SibDocks</string>
  <key>CFBundleDisplayName</key><string>SibDocks</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleExecutable</key><string>SibDocks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

if [ "$SIGNING_IDENTITY" = "-" ]; then
  # Ad-hoc signing is convenient for local development but is not suitable for
  # a public release: it does not satisfy Gatekeeper and its cdhash changes.
  codesign --force --sign - --identifier "$BUNDLE_IDENTIFIER" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ "$RESET_TCC" = "1" ]; then
  # Ad-hoc signing ties the Accessibility grant to the binary's cdhash, so
  # every local rebuild invalidates it. Clear the stale entry so the next
  # launch asks again instead of quitting silently.
  tccutil reset Accessibility "$BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
  echo "built $APP -- re-approve it in System Settings > Privacy & Security > Accessibility"
else
  echo "built $APP ($VERSION/$BUILD_NUMBER)"
fi
