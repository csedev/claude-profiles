#!/bin/bash
# Installs ClaudeProfiles.app to /Applications.
#
# Worth doing before enabling "Open at login": a login item records the bundle's
# path, and build/ClaudeProfiles.app is deleted and recreated by every build —
# which leaves macOS pointing at a bundle that no longer exists.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/ClaudeProfiles.app"
./Scripts/build-app.sh release

if pgrep -f "ClaudeProfiles.app/Contents/MacOS/ClaudeProfiles" >/dev/null; then
  echo "quitting running instance"
  pkill -f "ClaudeProfiles.app/Contents/MacOS/ClaudeProfiles" || true
  sleep 2
fi

rm -rf "$DEST"
cp -R build/ClaudeProfiles.app "$DEST"
echo "installed $DEST"
echo
echo "If 'Open at login' was enabled from a previous location, toggle it off and"
echo "on again so macOS records the new path."
open "$DEST"
