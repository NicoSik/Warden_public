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
expect_handoff "git commit" "$(bash_payload s1 'git commit -m x')"
expect_handoff "Skill tool call" '{"session_id":"s1","tool_name" : "Skill","tool_input":{"skill":"x"}}'
expect_handoff "git -C" "$(bash_payload s1 'git -C /x status')"
expect_handoff "graphify-setup" "$(bash_payload s1 '/p/graphify-setup')"
: > "$HOME/.claude/warden/nudge/s1.ready"
expect_handoff "main-session ls with marker" "$(bash_payload s1 'ls')"
expect_no_handoff "subagent ls with marker" "$(bash_payload s1 'ls' ',"agent_id":"a1"')"
expect_no_handoff "ls with no session_id" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
: > "$HOME/.claude/warden/nudge/s1.ready"
expect_handoff "sid is sanitized before the marker lookup" "$(bash_payload 's/1' 'ls')"

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

REPO="$HARNESS_TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '{"session_id":"s3","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$REPO" > "$HARNESS_TMP/commit.json"
ms=$(median_ms "$HARNESS_TMP/commit.json")
if [[ "$ms" =~ ^[0-9.]+$ ]] && awk -v m="$ms" 'BEGIN{exit !(m < 100)}'; then
  pass "REQ-10.2: median CPU of a git commit payload (not pending) is ${ms} ms (< 100)"
else
  fail "REQ-10.2: median CPU of a git commit payload (not pending) is ${ms} ms (want < 100)"
fi

harness_exit
