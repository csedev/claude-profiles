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

# PIDs of your running copies of the menu bar app, space-separated. Any copy,
# not only $DEST's: one left running from build/ would sit beside the new one.
#
# ps, not pgrep: pgrep never matches its own ancestors, and when this script runs
# from a Claude Code session in a profile's window, the menu bar app that opened
# the window is one. awk tests the executable alone, the first word of the
# command, so neither this script nor a process that only names the path in its
# arguments can match. -x without -a keeps to your own processes: another
# account's copy cannot be signalled from here.
running_pids() {
  ps -xww -o pid=,command= | awk '
    $2 ~ /(^|\/)ClaudeProfiles\.app\/Contents\/MacOS\/ClaudeProfiles$/ {
      printf "%s%s", sep, $1; sep = " "
    }'
}

pids="$(running_pids)"
if [ -n "$pids" ]; then
  echo "quitting running instance (pid $pids)"
  # shellcheck disable=SC2086 # split on purpose: one word per PID
  kill $pids || true
  for _ in {1..50}; do
    sleep 0.1
    pids="$(running_pids)"
    if [ -z "$pids" ]; then break; fi
  done
  # Replacing the bundle under a live copy, then opening the new one, leaves
  # two running.
  if [ -n "$pids" ]; then
    echo "still running after 5 seconds (pid $pids); quit it from the menu bar and run this again" >&2
    exit 1
  fi
fi

rm -rf "$DEST"
cp -R build/ClaudeProfiles.app "$DEST"
echo "installed $DEST"
echo
echo "If 'Open at login' was enabled from a previous location, toggle it off and"
echo "on again so macOS records the new path."

# open hands the app this shell's environment. From a Claude Code session that
# includes the session's own variables, CLAUDE_CONFIG_DIR among them, which
# describe the session and not the app, so strip them by Launcher's rule
# (strippedPrefixes, with keptDespitePrefix exempt).
open_env=(env)
for name in $(compgen -e); do
  case "$name" in
    CLAUDE_PROFILES_ROOT) ;; # ours: a relocated store stays relocated
    CLAUDE_* | CLAUDECODE* | ANTHROPIC_*) open_env+=(-u "$name") ;;
  esac
done
"${open_env[@]}" open "$DEST"
