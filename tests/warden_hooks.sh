#!/usr/bin/env bash
# REQ-1, REQ-2. The warden plugin injects the Code Map rule at SessionStart and SubagentStart.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

W="$REPO_DIR/plugins/warden"
S="$REPO_DIR/plugins/superpowers"
HOOK="$W/hooks/code-map"

for event in SessionStart SubagentStart; do
  out="$HARNESS_TMP/$event.json"
  "$HOOK" "$event" > "$out" 2>/dev/null
  if [ "$(jq -r '.hookSpecificOutput.hookEventName' "$out" 2>/dev/null)" = "$event" ]; then
    pass "$event output names the event"
  else
    fail "$event output does not parse or names the wrong event"
  fi
  jq -j '.hookSpecificOutput.additionalContext' "$out" > "$HARNESS_TMP/$event.txt" 2>/dev/null
  if cmp -s "$HARNESS_TMP/$event.txt" "$W/hooks/code-map.md"; then
    pass "$event additionalContext equals code-map.md byte for byte"
  else
    fail "$event additionalContext differs from code-map.md"
  fi
done

H="$W/hooks/hooks.json"
[ "$(jq '.hooks.SessionStart | length' "$H" 2>/dev/null)" = 1 ] && pass "one SessionStart entry" || fail "SessionStart must have one entry"
[ "$(jq '.hooks.SubagentStart | length' "$H" 2>/dev/null)" = 1 ] && pass "one SubagentStart entry" || fail "SubagentStart must have one entry"
[ "$(jq '.hooks.SubagentStart[0] | has("matcher")' "$H" 2>/dev/null)" = false ] && pass "SubagentStart has no matcher" || fail "SubagentStart must have no matcher"

wm=$(jq -r '.hooks.SessionStart[0].matcher' "$H" 2>/dev/null)
sm=$(jq -r '.hooks.SessionStart[0].matcher' "$S/hooks/hooks.json" 2>/dev/null)
if [ -n "$wm" ] && [ "$wm" = "$sm" ]; then
  pass "warden SessionStart matcher equals the Superpowers matcher ($wm)"
else
  fail "warden matcher '$wm' differs from Superpowers matcher '$sm'"
fi

for args in "" "NoSuchEvent"; do
  rc=0
  stdout=$("$HOOK" $args 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$stdout" ]; then
    pass "code-map '$args' exits non-zero with empty stdout"
  else
    fail "code-map '$args' must exit non-zero with empty stdout (rc=$rc)"
  fi
done

harness_exit
