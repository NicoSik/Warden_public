#!/usr/bin/env bash
# Offline tests for lib/merge_check.py on temporary trees.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
CHECK="$HERE/../lib/merge_check.py"

T=$(mktemp -d "${TMPDIR:-/tmp}/warden-mergecheck-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1

W="$T/warden"; M="$T/merged"
mkdir -p "$W/.claude-plugin" "$W/hooks" "$W/skills/demo"
printf '%s\n' '{"name":"warden"}' > "$W/.claude-plugin/plugin.json"
printf '%s\n' '{"plugins":[]}' > "$W/.claude-plugin/marketplace.json"
printf '%s\n' '{"hooks":{}}' > "$W/hooks/hooks.json"
printf '%s\n' 'rule' > "$W/hooks/code-map.md"
printf '%s\n' '# demo' > "$W/skills/demo/SKILL.md"
fresh() { rm -rf "$M"; mkdir -p "$M"; cp -R "$W/." "$M/"; }

# 1. full copy: exit 0, no output
fresh
out=$(python3 -I "$CHECK" "$W" "$M" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "1 full copy: exit 0, empty output" || fail "1 full copy rc=$rc out=$out"

# 2. deleted skill file
fresh; rm "$M/skills/demo/SKILL.md"
out=$(python3 -I "$CHECK" "$W" "$M" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$out" = "merge incomplete: skills/demo/SKILL.md" ] && pass "2 missing file: exit 2, names it" || fail "2 missing rc=$rc out=$out"

# 3. one byte differs
fresh; printf '%s\n' '# demx' > "$M/skills/demo/SKILL.md"
out=$(python3 -I "$CHECK" "$W" "$M" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$out" = "merge incomplete: skills/demo/SKILL.md" ] && pass "3 differing file: exit 2, names it" || fail "3 differ rc=$rc out=$out"

# 4. manifest files and hooks.json absent from merged tree
fresh; rm "$M/.claude-plugin/plugin.json" "$M/.claude-plugin/marketplace.json" "$M/hooks/hooks.json"
out=$(python3 -I "$CHECK" "$W" "$M" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "4 skipped files absent: exit 0" || fail "4 skipped rc=$rc out=$out"

[ "$FAILURES" -eq 0 ]
