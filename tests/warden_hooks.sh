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
  if [ "$event" = SubagentStart ]; then
    if cmp -s "$HARNESS_TMP/$event.txt" "$W/hooks/code-map.md"; then
      pass "$event additionalContext equals code-map.md byte for byte"
    else
      fail "$event additionalContext differs from code-map.md"
    fi
  fi
done

# REQ-1: SessionStart = code-map.md + setup-check.md with the placeholder replaced by the script path.
SETUP_PATH="$(cd -P "$W/scripts" && pwd)/graphify-setup"
PH='{{GRAPHIFY_SETUP}}'
if [ -f "$W/hooks/setup-check.md" ]; then
  want_text="$(cat "$W/hooks/code-map.md" && printf x)"; want_text="${want_text%x}"
  sc="$(cat "$W/hooks/setup-check.md" && printf x)"; sc="${sc%x}"
  printf '%s%s' "$want_text" "${sc//\{\{GRAPHIFY_SETUP\}\}/$SETUP_PATH}" > "$HARNESS_TMP/want.txt"
else
  : > "$HARNESS_TMP/want.txt"
fi
if [ -s "$HARNESS_TMP/want.txt" ] && cmp -s "$HARNESS_TMP/SessionStart.txt" "$HARNESS_TMP/want.txt"; then
  pass "SessionStart additionalContext equals code-map.md + setup-check.md with the script path"
else
  fail "SessionStart additionalContext differs from code-map.md + resolved setup-check.md"
fi
if grep -qF "\"$SETUP_PATH\" status" "$HARNESS_TMP/SessionStart.txt"; then
  pass "SessionStart holds the quoted command \"<path>\" status"
else
  fail "SessionStart lacks the quoted command \"$SETUP_PATH\" status"
fi

# A plugin root with a space: the quoted command must run as printed.
SP="$HARNESS_TMP/plugin root"
mkdir -p "$SP"
cp -R "$W/hooks" "$W/scripts" "$SP/"
jq -j '.hookSpecificOutput.additionalContext' <("$SP/hooks/code-map" SessionStart 2>/dev/null) > "$HARNESS_TMP/sp.txt" 2>/dev/null
SP_REAL="$(cd -P "$SP" && pwd)"
if grep -qF "\"$SP_REAL/scripts/graphify-setup\" status" "$HARNESS_TMP/sp.txt"; then
  pass "spaced plugin root: output holds the quoted path with the space"
else
  fail "spaced plugin root: quoted path missing from output"
fi
cmd="\"$SP_REAL/scripts/graphify-setup\" status"
mkdir -p "$HARNESS_TMP/repo"
git -C "$HARNESS_TMP/repo" init -q 2>/dev/null
word=$(cd "$HARNESS_TMP/repo" && bash -c "$cmd" 2>/dev/null) || true
case "$word" in
  ready|declined|small|no-cli|build|ask|unavailable) pass "spaced plugin root: printed command runs and prints '$word'" ;;
  *) fail "spaced plugin root: command printed '$word'" ;;
esac

# The placeholder appears exactly once; zero or two must fail loud.
n=$(grep -o -F "$PH" "$W/hooks/setup-check.md" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 1 ] && pass "setup-check.md holds the placeholder exactly once" || fail "setup-check.md holds the placeholder $n times (want 1)"
for count in 0 2; do
  d="$HARNESS_TMP/ph$count"
  mkdir -p "$d"
  cp -R "$W/hooks" "$W/scripts" "$d/"
  if [ "$count" = 0 ]; then
    printf 'no placeholder here\n' > "$d/hooks/setup-check.md"
  else
    printf '"%s" status\n"%s" status\n' "$PH" "$PH" > "$d/hooks/setup-check.md"
  fi
  rc=0
  stdout=$("$d/hooks/code-map" SessionStart 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$stdout" ]; then
    pass "$count placeholders: exits non-zero with empty stdout"
  else
    fail "$count placeholders must exit non-zero with empty stdout (rc=$rc)"
  fi
done

# A missing script must fail loud.
d="$HARNESS_TMP/noscript"
mkdir -p "$d"
cp -R "$W/hooks" "$d/"
rc=0
stdout=$("$d/hooks/code-map" SessionStart 2>/dev/null) || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$stdout" ]; then
  pass "missing scripts/graphify-setup exits non-zero with empty stdout"
else
  fail "missing scripts/graphify-setup must exit non-zero with empty stdout (rc=$rc)"
fi

# The text names no namespace and no skill.
if grep -qiE 'warden:|superpowers:|skill' "$W/hooks/setup-check.md" 2>/dev/null; then
  fail "setup-check.md names a namespace or a skill"
else
  [ -f "$W/hooks/setup-check.md" ] && pass "setup-check.md names no namespace and no skill" || fail "setup-check.md missing"
fi

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

# A missing rule file must fail loud, not inject an empty rule.
mkdir -p "$HARNESS_TMP/norule"
cp "$HOOK" "$HARNESS_TMP/norule/code-map"
rc=0
stdout=$("$HARNESS_TMP/norule/code-map" SessionStart 2>/dev/null) || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$stdout" ]; then
  pass "missing code-map.md exits non-zero with empty stdout"
else
  fail "missing code-map.md must exit non-zero with empty stdout (rc=$rc)"
fi

# The code-map hook must never block the session or a subagent: no entry sets onFailure.
n=$(jq '[.hooks[][].hooks[] | select(has("onFailure"))] | length' "$H" 2>/dev/null)
if [ "$n" = "0" ]; then
  pass "no hook entry in hooks.json sets onFailure"
else
  fail "hooks.json has $n hook entries with onFailure (must be 0)"
fi

# Trigger sentence: PR #2's text, restricted to the four skills.
SC="$W/hooks/setup-check.md"
if old_line=$(git -C "$REPO_DIR" show 5a972be:plugins/superpowers/skills/using-superpowers/SKILL.md 2>/dev/null | grep -m1 '^\*\*Setup check\.\*\*'); then
  old_trig="${old_line%%session.*}session."
  new_trig="$(head -n 1 "$SC")"; new_trig="${new_trig%%session.*}session."
  if [ "$old_trig" = "$new_trig" ]; then
    pass "setup-check.md trigger sentence equals PR #2's byte for byte"
  else
    fail "setup-check.md trigger sentence differs from PR #2 (want: $old_trig; got: $new_trig)"
  fi
else
  fail "cannot read commit 5a972be (shallow clone?): fetch full history to run this check"
fi
missing=""
for sk in brainstorming writing-plans writing-specs systematic-debugging; do
  grep -qF "$sk" "$SC" || missing="$missing $sk"
done
[ -z "$missing" ] && pass "setup-check.md names all four skills" || fail "setup-check.md misses:$missing"
if grep -qF 'graphify query' "$SC"; then
  fail "setup-check.md holds a stale 'graphify query' (code-map.md owns the Code Map rule)"
else
  pass "setup-check.md holds no 'graphify query'"
fi
n=$(grep -o -F 'graphify query' "$HARNESS_TMP/SessionStart.txt" | wc -l | tr -d ' ')
[ "$n" = 1 ] && pass "SessionStart additionalContext holds 'graphify query' exactly once" || fail "SessionStart additionalContext holds 'graphify query' $n times (want 1)"

harness_exit
