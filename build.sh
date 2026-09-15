#!/bin/sh
# Builds SibDocks.app. Run ./build.sh && open SibDocks.app
set -e
swift build -c release
APP=SibDocks.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SibDocks "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SibDocks</string>
  <key>CFBundleIdentifier</key><string>local.sibdocks</string>
  <key>CFBundleExecutable</key><string>SibDocks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc signing ties the Accessibility grant to the binary's cdhash, so every
# rebuild invalidates it and the app is denied without a prompt. Drop the stale
# TCC entry here so the next launch asks again instead of quitting silently.
codesign --force --sign - --identifier local.sibdocks "$APP"
tccutil reset Accessibility local.sibdocks >/dev/null 2>&1 || true
echo "built $APP -- re-approve it in System Settings > Privacy & Security > Accessibility"
