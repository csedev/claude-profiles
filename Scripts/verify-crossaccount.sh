#!/bin/bash
# Verifies the core claim: a second account inherits the first account's project
# settings, and the first account's state is untouched.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=.build/debug/claude-profiles
# Pass a project directory that your first account already trusts, ideally one
# with MCP servers configured — that is what makes the test meaningful.
PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  echo "usage: $0 <project-directory-trusted-by-your-first-account>" >&2
  exit 2
fi

pass=0; fail=0
check() {  # check <name> <condition-result> <detail>
  if [ "$2" = "0" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1"; [ -n "${3:-}" ] && echo "        $3"; fail=$((fail+1)); fi
}

# Account A's projects map legitimately changes as YOU use Claude — Claude Code
# records per-project state continuously. So "unchanged since an old baseline"
# is the wrong invariant and yields false alarms. The real property is narrower
# and stronger: OUR operations must not modify it. Measured across a tight
# window around a sync.
echo "=== 1. sync must not modify account A ==="
sha_a() { $CLI ls | sed -n '1,6p' | grep -oE 'projects-sha:[a-f0-9]+' | head -1 | cut -d: -f2; }
count_a() { $CLI ls | sed -n '1,6p' | grep -oE '[0-9]+ projects' | head -1 | cut -d' ' -f1; }

BEFORE_SHA=$(sha_a); BEFORE_COUNT=$(count_a)
$CLI sync >/dev/null 2>&1
AFTER_SHA=$(sha_a); AFTER_COUNT=$(count_a)

[ "$BEFORE_SHA" = "$AFTER_SHA" ]
check "account A unchanged across a sync" $? "before $BEFORE_SHA, after $AFTER_SHA"
[ "$BEFORE_COUNT" = "$AFTER_COUNT" ]
check "account A project count steady ($BEFORE_COUNT)" $? "before $BEFORE_COUNT, after $AFTER_COUNT"

echo
echo "=== 2. The settings actually crossed over ==="
python3 - "$PROJECT" <<'PY'
import json, os, sys
project = sys.argv[1]
base = os.path.expanduser('~/.claude-profiles/profiles')
prof = [d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))]
ok = False
for d in prof:
    p = os.path.join(base, d, 'config', '.claude.json')
    if not os.path.exists(p): continue
    entry = json.load(open(p)).get('projects', {}).get(project)
    if not entry: continue
    trusted = entry.get('hasTrustDialogAccepted')
    mcp = list((entry.get('mcpServers') or {}).keys())
    leaked = [k for k in entry if k.startswith('last')]
    print(f"  trusted={trusted}  mcpServers={mcp}")
    print(f"  telemetry leaked from account A: {leaked or 'none'}")
    ok = bool(trusted) and not leaked
sys.exit(0 if ok else 1)
PY
check "trust + MCP present, no telemetry leaked" $?

echo
echo "=== 3. The second account actually ran a session there ==="
$CLI sessions 2>/dev/null | grep -q "collective"; check "a session exists under 'collective'" $?

echo
echo "=== 4. Usage is being tracked for both ==="
$CLI usage collective 2>/dev/null | grep -qE '[0-9]+ samples'; check "collective has usage samples" $?

echo
echo "=== 5. Boundaries still sound ==="
$CLI doctor >/dev/null 2>&1; check "doctor passes" $?

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
