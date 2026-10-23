#!/usr/bin/env bash
# Offline test for the setup graders' input_match pattern. Never starts a real claude.
# It reads the pattern from each triggered.md and runs it with Python re.search.
# The golden fixtures in record_grading.sh replay stored verdicts, so they do not test this pattern.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
EV="$HERE/../evals"
WANT='graphify-setup\W{1,3}status'

# check FILE CASE EXPECT(match|none) STRING. The YAML double-quoted value is JSON-compatible
# for this pattern (only \\ and \" escapes), so json.loads unescapes it.
check() {
  local file="$1" name="$2" want="$3" str="$4" got
  got=$(python3 -I -c '
import json, re, sys
line = [l for l in open(sys.argv[1]) if l.startswith("input_match:")][0]
pat = json.loads(line.split(":", 1)[1].strip())
print("match" if re.search(pat, sys.argv[2]) else "none")' "$file" "$str" 2>&1)
  [ "$got" = "$want" ] && pass "$(basename "$(dirname "$(dirname "$file")")") case $name: $want" \
    || fail "$(basename "$(dirname "$(dirname "$file")")") case $name: want $want, got $got"
}

for d in setup-planning setup-quick-question setup-non-coding; do
  f="$EV/$d/graders/triggered.md"
  check "$f" 1 match '/x/plugins/warden/scripts/graphify-setup status'
  check "$f" 2 match '"/x y/plugins/warden/scripts/graphify-setup" status'
  check "$f" 3 match '{"command":"\"/x y/plugins/warden/scripts/graphify-setup\" status"}'
  check "$f" 4 match '/b/skills/brainstorming/../using-superpowers/scripts/graphify-setup status'
  check "$f" 5 none 'graphify-setup setup && echo status'
  [ "$(grep '^input_match:' "$f")" = "input_match: \"graphify-setup\\\\W{1,3}status\"" ] \
    && pass "$d pattern is $WANT" || fail "$d pattern is not $WANT"
done

[ "$FAILURES" -eq 0 ]
