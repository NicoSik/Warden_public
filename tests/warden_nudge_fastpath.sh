#!/usr/bin/env bash
# REQ-8, REQ-10. The setup-nudge bash prefilter: hand-off rules and CPU time of the fast path.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

REAL="$REPO_DIR/plugins/warden/hooks/setup-nudge"

# Stub plugin tree: warden-lesson only writes a flag file.
STUB="$HARNESS_TMP/stub"
mkdir -p "$STUB/hooks" "$STUB/scripts"
cp "$REAL" "$STUB/hooks/setup-nudge" 2>/dev/null
cat > "$STUB/scripts/warden-lesson" <<'PY'
import os, sys
sys.stdin.read()
open(os.environ["FLAG"], "w").close()
PY
export FLAG="$HARNESS_TMP/flag"
HOOK="$STUB/hooks/setup-nudge"

run_stub() { rm -f "$FLAG"; printf '%s' "$1" | "$HOOK" >/dev/null 2>&1; }
expect_handoff() {
  run_stub "$2"
  if [ -e "$FLAG" ]; then pass "hands off: $1"; else fail "should hand off: $1"; fi
}
expect_no_handoff() {
  run_stub "$2"
  if [ -e "$FLAG" ]; then fail "should not hand off: $1"; else pass "no hand-off: $1"; fi
}

bash_payload() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"/tmp"%s}' "$1" "$2" "${3:-}"; }

mkdir -p "$HOME/.claude/warden/nudge"
expect_no_handoff "ls with no marker" "$(bash_payload s1 'ls')"
expect_handoff "graphify-setup (no state file)" "$(bash_payload s1 '/p/graphify-setup')"
# Skill, git commit and git -C hand off only when <sid>.json exists (V4).
skill_payload() { printf '{"session_id":"s1","tool_name" : "Skill","tool_input":{"skill":"%s"}}' "$1"; }
for sk in superpowers:executing-plans superpowers:writing-plans; do
  expect_no_handoff "Skill $sk without state" "$(skill_payload $sk)"
done
expect_no_handoff "git commit without state" "$(bash_payload s1 'git commit -m x')"
expect_no_handoff "git -C without state" "$(bash_payload s1 'git -C x status')"
: > "$HOME/.claude/warden/nudge/s1.json"
for sk in superpowers:executing-plans superpowers:writing-plans; do
  expect_handoff "Skill $sk with state" "$(skill_payload $sk)"
done
expect_handoff "git commit with state" "$(bash_payload s1 'git commit -m x')"
expect_handoff "git -C with state" "$(bash_payload s1 'git -C x status')"
expect_no_handoff "ls with state only" "$(bash_payload s1 'ls')"
rm -f "$HOME/.claude/warden/nudge/s1.json"
: > "$HOME/.claude/warden/nudge/s1.ready"
expect_handoff "main-session ls with marker" "$(bash_payload s1 'ls')"
expect_no_handoff "subagent ls with marker" "$(bash_payload s1 'ls' ',"agent_id":"a1"')"
expect_no_handoff "ls with no session_id" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
: > "$HOME/.claude/warden/nudge/s1.ready"
expect_handoff "sid is sanitized before the marker lookup" "$(bash_payload 's/1' 'ls')"

# One hand-off test per trigger word (REQ-1.1 create words, git -C, graphify-setup).
rm -f "$HOME/.claude/warden/nudge/s1.ready"
for w in 'git init' 'git clone' 'create-next-app' 'npm create' 'pnpm create' 'yarn create' \
         'bun create' 'npx create-' 'cargo new' 'cargo init' 'uv init' 'graphify-setup'; do
  expect_handoff "trigger word '$w'" "$(bash_payload s1 "$w x")"
done

# Command output must not start Python: only the part before "tool_response" is scanned.
resp_payload() { # resp_payload SID CMD OUTPUT: Claude Code's key order, tool_input before tool_response
  printf '{"session_id":"%s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"stdout":"%s"}}' "$1" "$2" "$3"
}
RESP_LS=$(resp_payload s1 ls '(use \"git add\" and/or \"git commit -a\")')
expect_no_handoff "ls whose tool_response holds git commit -a" "$RESP_LS"
: > "$HOME/.claude/warden/nudge/s1.json"
expect_handoff "git commit with a tool_response" "$(resp_payload s1 'git commit -m x' 'done')"
rm -f "$HOME/.claude/warden/nudge/s1.json"
# tool_response first: no "tool_input" before it, so the whole payload is scanned.
expect_handoff "tool_response first, trigger after it (fallback)" \
  '{"session_id":"s1","tool_response":{"stdout":"ok"},"tool_name":"Bash","tool_input":{"command":"git init"}}'

# End to end: the real prefilter and the real warden-lesson turn a git init into a pending entry.
E2E="$HARNESS_TMP/e2e"
mkdir -p "$E2E"
: > "$E2E/transcript.jsonl"
sleep 1
git init -q "$E2E/proj"
printf '{"session_id":"e2e1","transcript_path":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git init proj"},"tool_response":{"stdout":"ok"}}' \
  "$E2E/transcript.jsonl" "$E2E" | "$REAL" >/dev/null 2>&1
if grep -q 'proj' "$HOME/.claude/warden/nudge/e2e1.json" 2>/dev/null; then
  pass "end to end: a git init payload creates a pending entry"
else
  fail "end to end: no pending entry in $HOME/.claude/warden/nudge/e2e1.json"
fi

# T13: the off switch.
rm -rf "$HOME/.claude/warden"
rc=0
OUT=$(printf '%s' "$(bash_payload s9 'git commit -m x')" | WARDEN_NUDGE_OFF=1 "$REAL" 2>&1) || rc=$?
if [ "$rc" = 0 ] && [ -z "$OUT" ] && [ ! -e "$HOME/.claude/warden" ]; then
  pass "T13: WARDEN_NUDGE_OFF=1 prints nothing and creates no state folder"
else
  fail "T13: off switch (rc=$rc, out='$OUT')"
fi

# Timing: median CPU time (user + sys of children) of 20 runs.
median_ms() {
  python3 -I -c '
import resource, subprocess, sys
payload = open(sys.argv[1], "rb").read()
t = []
for _ in range(20):
    a = resource.getrusage(resource.RUSAGE_CHILDREN)
    subprocess.run([sys.argv[2]], input=payload, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    b = resource.getrusage(resource.RUSAGE_CHILDREN)
    t.append(((b.ru_utime - a.ru_utime) + (b.ru_stime - a.ru_stime)) * 1000)
t.sort()
print("%.1f" % ((t[9] + t[10]) / 2))
' "$1" "$REAL"
}

bash_payload s2 ls > "$HARNESS_TMP/ls.json"
ms=$(median_ms "$HARNESS_TMP/ls.json")
if [[ "$ms" =~ ^[0-9.]+$ ]] && awk -v m="$ms" 'BEGIN{exit !(m < 20)}'; then
  pass "REQ-10.1: median CPU of an ls payload is ${ms} ms (< 20)"
else
  fail "REQ-10.1: median CPU of an ls payload is ${ms} ms (want < 20)"
fi

printf '{"session_id":"s5","tool_name":"Skill","tool_input":{"skill":"superpowers:writing-plans"}}' > "$HARNESS_TMP/skill.json"
ms=$(median_ms "$HARNESS_TMP/skill.json")
if [[ "$ms" =~ ^[0-9.]+$ ]] && awk -v m="$ms" 'BEGIN{exit !(m < 20)}'; then
  pass "REQ-10.1: median CPU of a Skill payload in a session without state is ${ms} ms (< 20)"
else
  fail "REQ-10.1: median CPU of a Skill payload in a session without state is ${ms} ms (want < 20)"
fi

rm -f "$HOME/.claude/warden/nudge/s1.ready"
printf '%s' "$RESP_LS" | sed 's/"s1"/"s4"/' > "$HARNESS_TMP/resp.json"
ms=$(median_ms "$HARNESS_TMP/resp.json")
if [[ "$ms" =~ ^[0-9.]+$ ]] && awk -v m="$ms" 'BEGIN{exit !(m < 20)}'; then
  pass "REQ-10.1: median CPU of an ls payload with a trigger word in tool_response is ${ms} ms (< 20)"
else
  fail "REQ-10.1: median CPU of an ls payload with a trigger word in tool_response is ${ms} ms (want < 20)"
fi

REPO="$HARNESS_TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '{"session_id":"s3","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$REPO" > "$HARNESS_TMP/commit.json"
mkdir -p "$HOME/.claude/warden/nudge"
printf '{"pending":{},"nudged":[],"dropped":[]}' > "$HOME/.claude/warden/nudge/s3.json"
ms=$(median_ms "$HARNESS_TMP/commit.json")
if [[ "$ms" =~ ^[0-9.]+$ ]] && awk -v m="$ms" 'BEGIN{exit !(m < 100)}'; then
  pass "REQ-10.2: median CPU of a git commit payload (not pending) is ${ms} ms (< 100)"
else
  fail "REQ-10.2: median CPU of a git commit payload (not pending) is ${ms} ms (want < 100)"
fi

harness_exit
