#!/bin/bash
# Assembles ClaudeProfiles.app from the SwiftPM executable.
#
# SwiftPM cannot emit a .app bundle, and a menu bar app needs one: LSUIElement
# keeps it out of the Dock and the app switcher, which is the whole point of
# living in the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/ClaudeProfiles.app"

swift build -c "$CONFIG" --product ClaudeProfilesApp
swift build -c "$CONFIG" --product claude-profiles

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
cp "$BIN/ClaudeProfilesApp" "$APP/Contents/MacOS/ClaudeProfiles"
cp "$BIN/claude-profiles"   "$APP/Contents/MacOS/claude-profiles"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundleDisplayName</key><string>Claude Profiles</string>
  <key>CFBundleIdentifier</key><string>io.github.csedev.claude-profiles</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "note: ad-hoc signing failed; the app still runs locally"

echo "built $APP"
