#!/usr/bin/env bash
# The PreToolUse hook that warns about zsh expansion pitfalls. Every fixture is synthetic.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SCRIPT="$REPO_DIR/plugins/warden/scripts/zsh-pitfalls"
HOOKS_JSON="$REPO_DIR/plugins/warden/hooks/hooks.json"
CWD="$(mktemp -d "$HARNESS_TMP/cwd.XXXXXX")"
mkdir -p "$CWD/sub" "$CWD/txtonly"
: > "$CWD/a.txt"; : > "$CWD/sub/b.py"; : > "$CWD/txtonly/c.txt"
export SHELL=/bin/zsh

# run_hook COMMAND [TOOL] [EVENT]: put the stdout in HOOK_OUT and the status in HOOK_RC.
run_hook() {
  local payload
  payload="$(python3 -I -c '
import json, sys
print(json.dumps({"hook_event_name": sys.argv[3], "tool_name": sys.argv[2], "cwd": sys.argv[4],
                  "tool_input": {"command": sys.argv[1]}}))' "$1" "${2:-Bash}" "${3:-PreToolUse}" "$CWD")"
  HOOK_OUT="$(printf '%s' "$payload" | python3 -I "$SCRIPT")"; HOOK_RC=$?
}
context() {
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"hookSpecificOutput"}, d
h = d["hookSpecificOutput"]
assert set(h) == {"hookEventName", "additionalContext"} and h["hookEventName"] == "PreToolUse", h
print(h["additionalContext"])' "$HOOK_OUT"
}

# reason: print the deny reason and assert that the output holds only the deny keys.
reason() {
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"hookSpecificOutput"}, d
h = d["hookSpecificOutput"]
assert set(h) == {"hookEventName", "permissionDecision", "permissionDecisionReason"}, h
assert h["hookEventName"] == "PreToolUse" and h["permissionDecision"] == "deny", h
print(h["permissionDecisionReason"])' "$HOOK_OUT"
}

# D1. The classes with zero false positives in the replay are denied, with the word in the reason.
while IFS=$'\t' read -r cmd word; do
  run_hook "$cmd"
  if [ "$HOOK_RC" = 0 ] && reason | grep -qF -- "$word"; then
    pass "denies: $cmd"
  else
    fail "no deny for: $cmd (rc=$HOOK_RC out='$HOOK_OUT')"
  fi
done <<'EOF'
grep -r foo --include=*.ts .	--include=*.ts
grep -r foo --include=*.ts --include=*.tsx . | head	--include=*.tsx
echo === done	===
[ "$a" == b ]	==
echo =====FILE	=====FILE
ls *.zzz; echo ===	===
EOF
run_hook 'ls *.zzz; echo ==='
reason | grep -qF -- '*.zzz' && pass "a deny reason also lists the warned words" || fail "deny reason lost the warning: $HOOK_OUT"

# D2. A word that zsh would accept is neither denied nor warned about.
: > "$CWD/--include=lit.zzq"
for cmd in 'echo =bash' 'grep x --include=*.zzq .'; do
  run_hook "$cmd"
  [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "silent, zsh accepts: $cmd" || fail "false alarm for: $cmd ('$HOOK_OUT')"
done

# D3. Expansions and unmeasured forms stay warnings.
for cmd in 'echo =$X' 'grep x --include=$X*' 'grep x --exclude=*.zzz .'; do
  run_hook "$cmd"
  if [ "$HOOK_RC" = 0 ] && context | grep -q Quote; then pass "warns only: $cmd"; else fail "not a plain warning: $cmd ('$HOOK_OUT')"; fi
done

# W1. Each command warns, and the warning names the word to quote.
while IFS=$'\t' read -r cmd word; do
  run_hook "$cmd"
  if [ "$HOOK_RC" = 0 ] && context | grep -qF -- "$word"; then
    pass "warns: $cmd"
  else
    fail "no warning for: $cmd (rc=$HOOK_RC out='$HOOK_OUT')"
  fi
done <<'EOF'
rm x include=*.tsx	include=*.tsx
ls *.zzz	*.zzz
ls /nonexistent-warden-dir/*	/nonexistent-warden-dir/*
curl https://x.test/a?b=1	https://x.test/a?b=1
cd sub && ls *.txt	*.txt
for f in *.zzz; do echo x; done	*.zzz
EOF

# W2. Each command stays silent.
while IFS= read -r cmd; do
  run_hook "$cmd"
  if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ]; then
    pass "silent: $cmd"
  else
    fail "false warning for: $cmd (rc=$HOOK_RC out='$HOOK_OUT')"
  fi
done <<'EOF'
grep --include='*.ts' x .
grep --include="*.ts" x .
grep --include=\*.ts x .
ls *.txt
cd sub && ls *.py
cd txtonly; ls *.txt
[[ $a == *.ts ]]
[ "$a" = b ]
case $x in *.ts) echo y;; esac
FOO=*.ts make build
export Y=*.ts
echo $((2*3))
echo ${x:-*}
ls $D/*.zzz
# ls *.zzz
bash -c 'ls *.zzz'
echo "==="
echo 'a=*.zzz' "b?c"
git log --format=%H
a=b
echo exit=$?
echo $*
EOF

# W3. Heredoc bodies are data.
run_hook $'cat > a <<\'EOF\'\n--include=*.ts\n===\nEOF'
[ -z "$HOOK_OUT" ] && pass "heredoc body stays silent" || fail "heredoc body warned: $HOOK_OUT"
run_hook $'cat > a <<EOF\nbody\nEOF\necho ==='
reason | grep -qF '===' && pass "command after a heredoc is still denied" || fail "command after heredoc: '$HOOK_OUT'"

# W4. The rules agree with real zsh.
if command -v zsh >/dev/null 2>&1; then
  ok=1
  for word in '--include=*.zzz' 'a=*.zzz' '===' '*.zzz'; do
    if (cd "$CWD" && zsh -c "print -r -- $word" >/dev/null 2>&1); then ok=0; echo "  zsh accepted $word"; fi
  done
  for word in "'--include=*.zzz'" '\*.zzz' '"==="' 'a.txt'; do
    if ! (cd "$CWD" && zsh -c "print -r -- $word" >/dev/null 2>&1); then ok=0; echo "  zsh rejected $word"; fi
  done
  [ "$ok" = 1 ] && pass "real zsh fails on the warned words and accepts the quoted forms" || fail "zsh disagrees with the rules"
else
  pass "zsh is not installed: real-shell check skipped"
fi

# W5. The hook never blocks and never speaks outside its case.
run_hook 'ls *.zzz' Read
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "other tools stay silent" || fail "other tool: '$HOOK_OUT'"
run_hook 'ls *.zzz' Bash PostToolUse
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "other events stay silent" || fail "other event: '$HOOK_OUT'"
SHELL=/bin/bash run_hook 'ls *.zzz'
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "a shell other than zsh stays silent" || fail "bash shell: '$HOOK_OUT'"
for bad in 'not json {' '[]' '{}' ; do
  OUT="$(printf '%s' "$bad" | python3 -I "$SCRIPT" 2>&1)"; RC=$?
  [ "$RC" = 0 ] && [ -z "$OUT" ] && pass "bad payload exits 0 quietly: $bad" || fail "bad payload $bad: rc=$RC out='$OUT'"
done
run_hook "echo 'unterminated"
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "unbalanced quote stays silent" || fail "unbalanced quote: '$HOOK_OUT'"

# W6. Three items at most. A warning sets no permission decision.
run_hook 'echo === ==== ===== ====== ======='
[ "$(reason | grep -c 'Quote')" -le 3 ] && pass "at most three items" || fail "too many items: $(reason)"
run_hook 'ls *.zzz *.zzy *.zzx *.zzw'
[ "$(context | grep -c 'Quote')" -le 3 ] && pass "at most three warnings" || fail "too many warnings: $(context)"
if printf '%s' "$HOOK_OUT" | grep -q 'permissionDecision'; then fail "a warning sets a permission decision"; else pass "a warning sets no permission decision"; fi

# W7. The registration is synchronous and scoped to Bash.
if python3 -I -c '
import json, sys
g = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
assert len(g) == 1 and g[0]["matcher"] == "Bash", g
h = g[0]["hooks"]
assert len(h) == 1 and h[0]["command"] == "python3 -I \"${CLAUDE_PLUGIN_ROOT}/scripts/zsh-pitfalls\"" and h[0]["async"] is False, h' "$HOOKS_JSON"; then
  pass "PreToolUse registers the hook for Bash, not in the background"
else
  fail "PreToolUse registration wrong"
fi

# W8. The hook runs before every Bash call, so it must be quick.
MED="$(python3 -I -c '
import json, os, statistics, subprocess, sys, time
p = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/", "tool_input": {"command": "grep -r x --include=*.ts . | head -5"}})
ts = []
for _ in range(20):
    t = time.perf_counter()
    subprocess.run(["python3", "-I", sys.argv[1]], input=p, text=True, capture_output=True)
    ts.append((time.perf_counter() - t) * 1000)
print("%.1f" % statistics.median(ts))' "$SCRIPT")"
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 50 else 1)' "$MED"; then pass "median of 20 runs is under 50 ms ($MED ms)"; else fail "median hook time $MED ms"; fi

harness_exit
