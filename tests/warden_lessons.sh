#!/usr/bin/env bash
# REQ-1, REQ-2, REQ-3, REQ-6, REQ-7, REQ-9. The lesson store, the secret scrub, retention and hook capture.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SCRIPT="${WARDEN_LESSON_SCRIPT:-$REPO_DIR/plugins/warden/scripts/warden-lesson}"
GUARD="$REPO_DIR/hooks/guard-secrets.sh"

# py CODE: run CODE with the script loaded as module `wl`. Extra args reach sys.argv[1:].
py() {
  local code="$1"; shift
  python3 -I -c '
import sys, importlib.machinery, importlib.util
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("wl", sys.argv[1])
spec = importlib.util.spec_from_loader("wl", loader)
wl = importlib.util.module_from_spec(spec)
loader.exec_module(wl)
code = sys.argv[2]
sys.argv[:] = ["wl"] + sys.argv[3:]
exec(code)
' "$SCRIPT" "$code" "$@"
}

fresh_root() { ROOT="$(mktemp -d "$HARNESS_TMP/root.XXXXXX")/inbox"; export WARDEN_LESSON_ROOT="$ROOT"; unset WARDEN_LESSON_OFF; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

# 1. Modes.
fresh_root
py 'assert wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "lesson", "text": "hi"})'
if [ "$(mode_of "$ROOT")" = 700 ] && [ "$(mode_of "$ROOT/manual.jsonl")" = 600 ]; then
  pass "inbox has mode 700 and file mode 600"
else
  fail "modes wrong: inbox $(mode_of "$ROOT" 2>/dev/null), file $(mode_of "$ROOT/manual.jsonl" 2>/dev/null)"
fi
py 'assert wl.write_line(wl.inbox() + "/sessions/s1.jsonl", {"t": "edit"})'
[ "$(mode_of "$ROOT/sessions")" = 700 ] && pass "sessions folder has mode 700" || fail "sessions mode wrong"

# 2. 512-byte cap.
fresh_root
py 'assert wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "lesson", "text": "x" * 5000, "repo": "é" * 5000})'
if python3 -I -c 'import json,sys
b=open(sys.argv[1],"rb").read()
assert len(b)<=513 and b.endswith(b"\n") and b.count(b"\n")==1
json.loads(b)' "$ROOT/manual.jsonl"; then
  pass "5000-character values give one valid JSON line of at most 512 bytes"
else
  fail "long value line is invalid or over 512 bytes"
fi
py '
wl.write_line(wl.inbox() + "/c.jsonl", {"cmd": "c " * 50, "sig": "s " * 150, "text": "t " * 200})
import json
d = json.loads(open(wl.inbox() + "/c.jsonl").read())
assert (len(d["cmd"]), len(d["sig"]), len(d["text"])) == (40, 120, 200), d' \
  && pass "per-key caps are 40, 120 and 200" || fail "per-key caps wrong"

# 3. Planted secrets never reach the file.
fresh_root
PLANTS=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "AKIAABCDEFGHIJKLMNOP"
  "ASIAABCDEFGHIJKLMNOP"
  "ghp_abcdefghijklmnopqrstuvwx"
  "sk-ant-abcdefghijklmnopqrstu"
  "xoxb-1234567890-abcdef"
  "Bearer abcdefghijklmnop"
  "Authorization: Basic dXNlcjpwYXNzd29yZA=="
  "password=hunter2hunter2"
  "TOKEN=zzzTOKENvalue9"
  "secret=s3cr3tvalue"
  "api_key=apikeyvalue123"
)
for p in "${PLANTS[@]}"; do
  py 'wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "lesson", "text": "before " + sys.argv[1] + " after"})' "$p" || true
done
# Search for the secret part of each plant.
SECRETS=("PRIVATE KEY-----" "AKIAABCDEFGHIJKLMNOP" "ASIAABCDEFGHIJKLMNOP" "ghp_abcdefghij" "sk-ant-abcdef" "xoxb-1234567890" "abcdefghijklmnop" "dXNlcjpwYXNz" "hunter2hunter2" "zzzTOKENvalue9" "s3cr3tvalue" "apikeyvalue123")
leak=0
for s in "${SECRETS[@]}"; do
  if grep -rqF -- "$s" "$ROOT"; then fail "planted value leaked: $s"; leak=1; fi
done
if [ "$leak" = 0 ] && [ "$(wc -l < "$ROOT/manual.jsonl" 2>/dev/null | tr -d ' ')" = "${#PLANTS[@]}" ]; then
  pass "no planted secret reaches the inbox"
else
  fail "planted secrets: leak=$leak or line count wrong"
fi

# 4. Coverage of every shape in hooks/guard-secrets.sh.
SHAPES=()
while IFS= read -r line; do SHAPES+=("$line"); done < <(grep -E "grep -E[iq]+ " "$GUARD" | sed -E "s/.*grep -E[iq]+ (-- )?'(.*)'; then.*/\2/")
SAMPLES=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "AKIAABCDEFGHIJKLMNOP"
  "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
)
if [ "${#SHAPES[@]}" != "${#SAMPLES[@]}" ]; then
  fail "guard-secrets.sh holds ${#SHAPES[@]} shapes, this test knows ${#SAMPLES[@]}: add samples"
else
  for i in "${!SHAPES[@]}"; do
    # Convert the POSIX class so BSD and GNU grep agree; the sample must match the shape.
    if ! printf '%s' "${SAMPLES[$i]}" | grep -Eiq -- "${SHAPES[$i]}"; then
      fail "sample $i does not match guard shape ${SHAPES[$i]}"; continue
    fi
    if py 'out = wl.scrub("x " + sys.argv[1] + " y"); assert "<secret>" in out and sys.argv[1] not in out, out' "${SAMPLES[$i]}"; then
      pass "scrub replaces guard shape $((i+1))"
    else
      fail "scrub misses guard shape ${SHAPES[$i]}"
    fi
  done
fi

# 5. Inbox inside a git work tree.
GITDIR="$(mktemp -d "$HARNESS_TMP/git.XXXXXX")"
git -C "$GITDIR" init -q
export WARDEN_LESSON_ROOT="$GITDIR/deep/inbox"
if py 'assert wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "edit"}) is False; assert "inside a git work tree" in wl.blocked_reasons()' \
   && [ ! -e "$GITDIR/deep" ]; then
  pass "inbox in a git work tree: write_line returns False, nothing written"
else
  fail "inbox in a git work tree was written or not blocked"
fi

# 6. Read-only inbox.
fresh_root
mkdir -p "$ROOT" && chmod 500 "$ROOT"
if py 'assert wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "edit"}) is False' >/dev/null 2>&1 \
   && [ -z "$(ls -A "$ROOT")" ]; then
  pass "read-only inbox: write_line returns False, nothing written"
else
  fail "read-only inbox was written"
fi
chmod 700 "$ROOT"

# 7. Retention.
fresh_root
mkdir -p "$ROOT/sessions"
: > "$ROOT/sessions/old.jsonl"; : > "$ROOT/sessions/recent.jsonl"; : > "$ROOT/manual.jsonl"
d31=$(date -v-31d +%Y%m%d0000 2>/dev/null || date -d '31 days ago' +%Y%m%d0000)
d29=$(date -v-29d +%Y%m%d0000 2>/dev/null || date -d '29 days ago' +%Y%m%d0000)
d40=$(date -v-40d +%Y%m%d0000 2>/dev/null || date -d '40 days ago' +%Y%m%d0000)
touch -t "$d31" "$ROOT/sessions/old.jsonl"
touch -t "$d29" "$ROOT/sessions/recent.jsonl"
touch -t "$d40" "$ROOT/manual.jsonl"
py 'wl.retention()'
if [ ! -e "$ROOT/sessions/old.jsonl" ] && [ -e "$ROOT/sessions/recent.jsonl" ] && [ -e "$ROOT/manual.jsonl" ]; then
  pass "retention deletes only the 31-day session log"
else
  fail "retention result wrong"
fi
: > "$ROOT/sessions/old2.jsonl"; touch -t "$d31" "$ROOT/sessions/old2.jsonl"
py 'wl.retention()'
[ -e "$ROOT/sessions/old2.jsonl" ] && pass "second call on the same day deletes nothing new" || fail "retention ran twice in one day"

# 8. PEM blocks, base64 runs and hex tokens (leak through the sig fallback).
fresh_root
B64="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2"
HEX="0123456789abcdef0123456789abcdef01234567"
PEM="-----BEGIN RSA PRIVATE KEY-----
$B64
-----END RSA PRIVATE KEY-----"
for t in "$PEM" "$B64" "$HEX"; do
  py 'wl.write_line(wl.inbox() + "/manual.jsonl", {"t": "lesson", "text": sys.argv[1]})' "$t" || true
done
if grep -qF -- "$B64" "$ROOT/manual.jsonl" || grep -qF -- "$HEX" "$ROOT/manual.jsonl" || grep -qF -- "END RSA" "$ROOT/manual.jsonl"; then
  fail "PEM body, base64 run or hex token leaked"
else
  pass "PEM body, base64 run and hex token never reach the inbox"
fi
if py '
w39 = "a" * 39
assert wl.scrub(w39) == w39
s = "run /usr/local/bin/python3.12 now, then check the file."
assert wl.scrub(s) == s, wl.scrub(s)
assert wl.scrub("x " + "a" * 40) == "x <secret>"
assert "<secret>" in wl.scrub("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")
assert "abc" not in wl.scrub("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")
'; then
  pass "ordinary text survives the scrub"
else
  fail "scrub altered ordinary text or missed a case"
fi

# 9. Pointer keys keep long runs; named shapes still apply to them.
fresh_root
if py '
import json
TP = "/Volumes/x/.claude/projects/-Users-x-Warden-public-code-map/0d58bfb4-0612-44d9-8983-96d3a37be97e.jsonl"
SID = "0d58bfb4-0612-44d9-8983-96d3a37be97e"
TU = "toolu_01ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"
B64 = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2"
assert wl.write_line(wl.inbox() + "/a.jsonl", {"t": "fail", "transcript_path": TP, "session_id": SID, "tool_use_id": TU, "sig": B64})
d = json.loads(open(wl.inbox() + "/a.jsonl").read())
assert (d["transcript_path"], d["session_id"], d["tool_use_id"]) == (TP, SID, TU), d
assert d["sig"] == "<secret>", d
assert wl.write_line(wl.inbox() + "/b.jsonl", {"t": "fail", "transcript_path": "/p/AKIAABCDEFGHIJKLMNOP/x.jsonl"})
d = json.loads(open(wl.inbox() + "/b.jsonl").read())
assert "AKIA" not in d["transcript_path"], d
'; then
  pass "pointer keys stay unchanged, sig run and named shape in a pointer are replaced"
else
  fail "pointer key handling wrong"
fi
# 9b. branch and commit skip only the long-run rule, like the pointer keys.
fresh_root
BR45="feature/lesson-capture-and-some-more-words-xy"
if [ "${#BR45}" = 45 ] && py '
import json, sys
BR = sys.argv[1]
SIG = "a" * 45
assert wl.write_line(wl.inbox() + "/a.jsonl", {"t": "fail", "branch": BR, "commit": "e" * 40, "sig": SIG})
d = json.loads(open(wl.inbox() + "/a.jsonl").read())
assert d["branch"] == BR, d
assert d["commit"] == "e" * 40, d
assert d["sig"] == "<secret>", d
assert wl.write_line(wl.inbox() + "/b.jsonl", {"t": "fail", "branch": "feature/AKIAABCDEFGHIJKLMNOP"})
d = json.loads(open(wl.inbox() + "/b.jsonl").read())
assert "AKIA" not in d["branch"] and "<secret>" in d["branch"], d
' "$BR45"; then
  pass "branch and commit keep long runs, named shape in branch replaced, sig run still replaced"
else
  fail "branch/commit exemption wrong"
fi
# ---- Hook capture (REQ-1, REQ-2, REQ-3, REQ-9) ----
SID="0d58bfb4-0612-44d9-8983-96d3a37be97e"
TP="/Volumes/x/.claude/projects/p/$SID.jsonl"
REPO="$(mktemp -d "$HARNESS_TMP/proj.XXXXXX")/myrepo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"

# payload EVENT TOOL COMMAND ERROR [INTERRUPT]: print a synthetic payload as JSON.
payload() {
  python3 -I -c '
import json, os, sys
ev, tool, cmd, err, intr, cwd = sys.argv[1:7]
p = {"hook_event_name": ev, "tool_name": tool, "session_id": "'"$SID"'", "transcript_path": "'"$TP"'",
     "tool_use_id": "toolu_01ABC", "cwd": cwd, "tool_input": {"command": cmd}, "is_interrupt": intr == "1"}
if ev == "PostToolUseFailure":
    p["error"] = err
else:
    p["tool_response"] = {"stdout": os.environ.get("PAYLOAD_STDOUT", ""), "stderr": "", "interrupted": False}
print(json.dumps(p))' "$1" "$2" "$3" "$4" "${5:-0}" "${HOOK_CWD:-$REPO}"
}
sess() { echo "$ROOT/sessions/$SID.jsonl"; }
nlines() { [ -f "$(sess)" ] && wc -l < "$(sess)" | tr -d ' ' || echo 0; }
# run_hook PAYLOAD: run the hook, return its stdout+stderr in HOOK_OUT and its status in HOOK_RC.
run_hook() {
  HOOK_OUT="$(printf '%s' "$1" | python3 -I "$SCRIPT" hook 2>&1)"; HOOK_RC=$?
}
fail_payload() { payload PostToolUseFailure Bash "$1" "$2" "${3:-0}"; }
# jl FIELD [LINE]: print FIELD of line LINE (default last) of the session log.
jl() {
  python3 -I -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
d = json.loads(lines[int(sys.argv[3])])
print(d.get(sys.argv[2], "<absent>"))' "$(sess)" "$1" "${2:--1}"
}
keys() {
  python3 -I -c '
import json, sys
print(",".join(sorted(json.loads(open(sys.argv[1]).read().splitlines()[-1]))))' "$(sess)"
}

# H1. false: exit 1, no output.
fresh_root
run_hook "$(fail_payload false 'Exit code 1')"
FAILKEYS="branch,cmd,commit,exit,repo,session_id,sig,src,t,tool_use_id,transcript_path,ts"
if [ "$(nlines)" = 1 ] && [ "$(jl t)" = fail ] && [ "$(jl cmd)" = false ] && [ -z "$(jl sig)" ] \
   && [ "$(keys)" = "$FAILKEYS" ] && [ "$(jl exit)" = 1 ] && [ "$(jl src)" = hook ] \
   && [ "$(jl repo)" = myrepo ] && [ "$(jl branch)" = main ] && [ "$(jl commit)" = "$COMMIT" ] \
   && [ "$(jl session_id)" = "$SID" ] && [ "$(jl transcript_path)" = "$TP" ] \
   && jl ts | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'; then
  pass "false: one fail line with the exact key set and git fields"
else
  fail "false: line wrong: $(cat "$(sess)" 2>/dev/null)"
fi

# H2. pytest-style failure.
fresh_root
ERR=$'Exit code 1\n============ test session starts ============\ncollected 3 items\ntests/test_x.py F..\nE   AssertionError: assert 2 == 3 in /Volumes/x/proj/tests/test_x.py\nFAILED tests/test_x.py::test_add - AssertionError'
run_hook "$(fail_payload 'pytest -q' "$ERR")"
SIG="$(jl sig)"
if [ "$SIG" = "E   AssertionError: assert 2 == 3 in <path>" ] || [ "$SIG" = "E AssertionError: assert 2 == 3 in <path>" ]; then
  pass "pytest failure: sig is the E line with the path replaced"
else
  fail "pytest sig wrong: '$SIG'"
fi
if [ "$(jl h)" != "<absent>" ] && [ ${#SIG} -le 120 ]; then pass "test-like fail line holds h"; else fail "test-like fail line has no h"; fi
EXPECTH="$(python3 -I -c 'import hashlib,sys;print(hashlib.sha256((sys.argv[1]+"\0"+sys.argv[2]).encode()).hexdigest()[:16])' 'pytest -q' "$REPO")"
[ "$(jl h)" = "$EXPECTH" ] && pass "h is sha256(command, zero byte, cwd), 16 hex characters" || fail "h wrong: $(jl h) vs $EXPECTH"

# H3. No matching line: last non-empty line.
fresh_root
run_hook "$(fail_payload 'make build' $'Exit code 2\nstep one\nstep two\n\n')"
[ "$(jl sig)" = "step two" ] && pass "no matching line: sig is the last non-empty line" || fail "last-line sig wrong: '$(jl sig)'"
[ "$(jl h)" = "<absent>" ] && pass "non-test fail line has no h" || fail "non-test fail line holds h"

# H4. Skips.
fresh_root
run_hook "$(fail_payload 'make x' 'Exit code 0')"
run_hook "$(fail_payload 'make x' 'Exit code 130')"
run_hook "$(fail_payload 'make x' 'Exit code 143')"
run_hook "$(fail_payload 'make x' 'Exit code 2' 1)"
run_hook "$(fail_payload 'grep foo x' 'Exit code 1')"
run_hook "$(fail_payload 'cd a && rg x' 'Exit code 1')"
run_hook "$(fail_payload 'git diff --quiet' 'Exit code 1')"
run_hook "$(fail_payload 'test -f x' 'Exit code 1')"
run_hook "$(payload PostToolUseFailure Edit 'x' 'Exit code 2')"
[ "$(nlines)" = 0 ] && pass "skipped exits, interrupt, quiet-check commands and non-Bash write nothing" || fail "a skipped payload wrote: $(cat "$(sess)")"
run_hook "$(fail_payload 'grep foo x' 'Exit code 2')"
[ "$(nlines)" = 1 ] && pass "grep with exit 2 writes a line" || fail "grep exit 2 wrote nothing"

# H5. cmd.
fresh_root
LONGW="$(printf 'abcdefghi.%.0s' $(seq 1 6))"
run_hook "$(fail_payload 'git push origin main' 'Exit code 1')"
run_hook "$(fail_payload '/usr/bin/python3 -c x' 'Exit code 1')"
run_hook "$(fail_payload "$LONGW arg" 'Exit code 1')"
if [ "$(jl cmd 0)" = "git push" ] && [ "$(jl cmd 1)" = python3 ] && [ "$(jl cmd 2)" = "$(printf 'abcdefghi.%.0s' 1 2 3 4)" ]; then
  pass "cmd: git push, python3, 60-character word cut to 40"
else
  fail "cmd wrong: '$(jl cmd 0)' '$(jl cmd 1)' '$(jl cmd 2)'"
fi

# H6. Test-like list, pass and edit lines.
if py '
for c in ["pytest -q", "py.test x", "jest", "vitest run", "mocha", "rspec", "tox", "python -m pytest", "python -m unittest",
          "python3 -m pytest -x", "python3 -m unittest d", "npm test", "pnpm test", "yarn test", "bun test", "cargo test",
          "go test ./...", "dotnet test", "mix test", "gradle test", "mvn test", "make test", "make check",
          "bash tests/run.sh", "cd x && ./test/a.sh"]:
    assert wl.is_test_like(c), c
for c in ["ls", "make build", "npm install", "bash run.sh", "echo pytest"]:
    assert not wl.is_test_like(c), c
'; then pass "test-like list matches REQ-3.1 case by case"; else fail "test-like list wrong"; fi
fresh_root
run_hook "$(payload PostToolUse Bash 'pytest -q' '')"
if [ "$(nlines)" = 1 ] && [ "$(keys)" = "h,t,tool_use_id,ts" ] && [ "$(jl t)" = pass ]; then
  pass "PostToolUse pytest writes a pass line with exactly t, ts, tool_use_id, h"
else fail "pass line wrong: $(cat "$(sess)" 2>/dev/null)"; fi
run_hook "$(payload PostToolUse Bash 'ls' '')"
[ "$(nlines)" = 1 ] && pass "PostToolUse ls writes nothing" || fail "ls wrote a line"
for tool in Edit Write MultiEdit NotebookEdit; do
  run_hook "$(payload PostToolUse "$tool" 'x' '')"
  if [ "$(jl t)" = edit ] && [ "$(keys)" = "t,ts" ]; then pass "$tool writes an edit line with exactly t, ts"; else fail "$tool line wrong"; fi
done

# H7. The full command text never appears.
fresh_root
run_hook "$(fail_payload 'git push origin UNIQUEMARKER42' 'Exit code 1')"
run_hook "$(payload PostToolUse Bash 'pytest -q UNIQUEMARKER42' '')"
if [ "$(nlines)" = 2 ] && ! grep -rq UNIQUEMARKER42 "$ROOT"; then pass "full command text never reaches the inbox"; else fail "marker leaked or lines missing"; fi

# H8. A planted secret in the failure output.
fresh_root
run_hook "$(fail_payload 'curl x' $'Exit code 22\nerror: denied for password=hunter2hunter2 and ghp_abcdefghijklmnopqrstuvwx')"
if [ "$(nlines)" = 1 ] && ! grep -rqE 'hunter2|ghp_abcdef' "$ROOT"; then pass "secret in failure output is not in the inbox"; else fail "secret leaked: $(cat "$(sess)" 2>/dev/null)"; fi

# H9. Off switch, bad JSON, read-only inbox.
fresh_root
OUT="$(WARDEN_LESSON_OFF=1 python3 -I "$SCRIPT" hook </dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$ROOT" ]; then pass "WARDEN_LESSON_OFF=1 with no stdin exits 0 and writes nothing"; else fail "off switch: rc=$RC out='$OUT'"; fi
OUT="$(printf '%s' "$(fail_payload false 'Exit code 1')" | WARDEN_LESSON_OFF=1 python3 -I "$SCRIPT" hook 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$ROOT" ]; then pass "WARDEN_LESSON_OFF=1 with a payload writes nothing"; else fail "off switch with payload"; fi
run_hook 'not json {'
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && pass "invalid JSON exits 0 with no output" || fail "invalid JSON: rc=$HOOK_RC out='$HOOK_OUT'"
fresh_root
mkdir -p "$ROOT" && chmod 500 "$ROOT"
run_hook "$(fail_payload false 'Exit code 1')"
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && [ -z "$(ls -A "$ROOT")" ]; then pass "read-only inbox exits 0 with no output"; else fail "read-only inbox: rc=$HOOK_RC out='$HOOK_OUT'"; fi
chmod 700 "$ROOT"

# H10. Timing: median of 20 runs under 50 ms.
fresh_root
FP="$(fail_payload 'pytest -q' $'Exit code 1\nE   AssertionError: x')"
MED="$(python3 -I -c '
import subprocess, sys, time, statistics
ts = []
for _ in range(20):
    t = time.perf_counter()
    subprocess.run(["python3", "-I", sys.argv[1], "hook"], input=sys.argv[2], text=True, capture_output=True)
    ts.append((time.perf_counter() - t) * 1000)
print("%.1f" % statistics.median(ts))' "$SCRIPT" "$FP")"
echo "  median hook time: ${MED} ms"
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 50 else 1)' "$MED"; then pass "median of 20 hook runs is under 50 ms ($MED ms)"; else fail "median hook time $MED ms"; fi

# ---- Task 3: add, list, status, bin wrapper (REQ-4, REQ-5, REQ-11) ----
unset CLAUDE_CODE_SESSION_ID
NROOT_SET() { NROOT="$(python3 -I -c "import os,sys;print(os.path.abspath(sys.argv[1]))" "$ROOT")"; }
WL() { python3 -I "$SCRIPT" "$@"; }
jfail() { printf '{"t":"fail","ts":"%s","src":"hook","cmd":"%s","exit":1,"sig":"%s","session_id":"s","transcript_path":"","tool_use_id":"%s","repo":"r","branch":"b","commit":"c"%s}\n' "$1" "$2" "$3" "$4" "$5"; }
jq1() { python3 -I -c 'import sys,json
rs=[json.loads(l) for l in sys.stdin]
'"$1"; }

# L1. Repeated failure groups into one record.
fresh_root; mkdir -p "$ROOT/sessions"
for i in 1 2 3; do jfail "2026-10-01T00:00:0${i}Z" "make" "boom" "u$i" ""; done > "$ROOT/sessions/a.jsonl"
if WL list --json | jq1 'assert len(rs)==1 and rs[0]["count"]==3, rs'; then pass "3 identical fails give one record, count 3"; else fail "repeated failure grouping"; fi

# L2. Digit runs normalise in the key; first sig kept.
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" "node" "Error: port 3000 in use" u1 ""; jfail "2026-10-01T00:00:02Z" "node" "Error: port 3001 in use" u2 ""; } > "$ROOT/sessions/a.jsonl"
if WL list --json | jq1 'assert len(rs)==1 and rs[0]["count"]==2 and rs[0]["sig"]=="Error: port 3000 in use", rs'; then pass "numbers-only differences group, first sig kept"; else fail "digit normalisation"; fi

# L3. Fixed test with two edits.
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" "pytest" "E boom" u1 ',"h":"abcd1234abcd1234"'
  echo '{"t":"edit","ts":"2026-10-01T00:00:02Z"}'; echo '{"t":"edit","ts":"2026-10-01T00:00:03Z"}'
  echo '{"t":"pass","ts":"2026-10-01T00:00:04Z","tool_use_id":"tu_pass","h":"abcd1234abcd1234"}'; } > "$ROOT/sessions/a.jsonl"
if WL list --json | jq1 'r=rs[0]; assert r["fixed"] is True and r["fixed_by"]=="tu_pass" and r["edits"]==2, r'; then pass "fixed test shows pass id and 2 edits"; else fail "fixed with edits"; fi
WL list | grep -q 'fixed' && pass "list text shows fixed" || fail "list text lacks fixed"

# L4. Plain rerun: edits 0.
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" "pytest" "E boom" u1 ',"h":"abcd1234abcd1234"'
  echo '{"t":"pass","ts":"2026-10-01T00:00:04Z","tool_use_id":"tu_pass","h":"abcd1234abcd1234"}'; } > "$ROOT/sessions/a.jsonl"
if WL list --json | jq1 'r=rs[0]; assert r["fixed"] is True and r["edits"]==0, r'; then pass "plain rerun shows edits 0"; else fail "plain rerun"; fi

# L5. Corrupt line skipped.
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" "make" "boom" u1 ""; echo '{not json'; jfail "2026-10-01T00:00:02Z" "ls" "nope" u2 ""; } > "$ROOT/sessions/a.jsonl"
if WL list --json | jq1 'assert len(rs)==2, rs'; then pass "corrupt line skipped, others listed"; else fail "corrupt line"; fi

# L6. add.
fresh_root
WL add "fix the flaky port test" >/dev/null; WL add --by agent "x" >/dev/null
WL add "leak ghp_abcdefghijklmnopqrstuvwxyz0123456789 here" >/dev/null
WL add "$(python3 -I -c 'print("w "*150)')" >/dev/null
CLAUDE_CODE_SESSION_ID=abc WL add "with sid" >/dev/null
if python3 -I -c 'import sys,json
ls=[json.loads(l) for l in open(sys.argv[1])]
assert ls[0]["src"]=="user" and ls[0]["t"]=="lesson" and ls[0]["text"]=="fix the flaky port test" and "session_id" not in ls[0], ls[0]
assert ls[1]["src"]=="agent"
assert len(ls[3]["text"])==200, len(ls[3]["text"])
assert ls[4]["session_id"]=="abc"
assert set(ls[0])=={"t","ts","src","text","repo","branch","commit"}, set(ls[0])' "$ROOT/manual.jsonl" && ! grep -q ghp_ "$ROOT/manual.jsonl"; then pass "add: src, scrub, 200 cap, session_id, keys"; else fail "add behaviour"; fi
OUT="$(WL add 2>&1)"; RC=$?
if [ "$RC" = 2 ] && [ "$OUT" = 'usage: warden-lesson add "<text>" [--by agent]' ]; then pass "add without text exits 2 with usage"; else fail "add usage: rc=$RC out=$OUT"; fi

# L7. Ordering and --json.
fresh_root; mkdir -p "$ROOT/sessions"
jfail "2026-10-01T00:00:01Z" "oldcmd" "old" u1 "" > "$ROOT/sessions/a.jsonl"
jfail "2026-10-05T00:00:01Z" "newcmd" "new" u2 "" > "$ROOT/sessions/b.jsonl"
printf '{"t":"lesson","ts":"2026-10-03T00:00:00Z","src":"user","text":"mid lesson","repo":"r","branch":"b","commit":"c"}\n' > "$ROOT/manual.jsonl"
ORDER="$(WL list | awk '{print $0}' | grep -o 'newcmd\|mid lesson\|oldcmd' | tr '\n' ,)"
[ "$ORDER" = "newcmd,mid lesson,oldcmd," ] && pass "list is newest first" || fail "list order: $ORDER"
WL list | grep -q ' user ' && pass "list shows src" || fail "list lacks src"
WL list --json | jq1 'assert len(rs)==3' && pass "list --json gives valid JSON lines" || fail "list --json"

# L8. status.
fresh_root
NROOT_SET; OUT="$(WL status)"; RC=$?
if [ "$RC" = 0 ] && grep -qx "inbox: $NROOT" <<<"$OUT" && grep -qx 'capture: enabled' <<<"$OUT" && grep -qx 'records: 0' <<<"$OUT" && grep -qx 'last write: never' <<<"$OUT"; then pass "status on empty inbox"; else fail "status empty: $OUT"; fi
WL add one >/dev/null; WL add two >/dev/null
LASTTS="$(python3 -I -c 'import sys,json
print(json.loads(open(sys.argv[1]).readlines()[-1])["ts"])' "$ROOT/manual.jsonl")"
OUT="$(WL status)"
if grep -qx 'records: 2' <<<"$OUT" && grep -qx "last write: $LASTTS" <<<"$OUT"; then pass "status after two writes"; else fail "status count: $OUT"; fi
OUT="$(WARDEN_LESSON_OFF=1 WL status)"; RC=$?
if [ "$RC" = 0 ] && grep -qx 'capture: disabled (WARDEN_LESSON_OFF is 1)' <<<"$OUT"; then pass "status shows OFF reason"; else fail "status off: $OUT"; fi
chmod 500 "$ROOT"; OUT="$(WL status)"; RC=$?; chmod 700 "$ROOT"
if [ "$RC" = 0 ] && grep -qx 'capture: disabled (not writable)' <<<"$OUT"; then pass "status shows not writable"; else fail "status ro: $OUT"; fi
G="$(mktemp -d "$HARNESS_TMP/git.XXXXXX")"; git -C "$G" init -q
OUT="$(WARDEN_LESSON_ROOT="$G/inbox" WL status)"; RC=$?
if [ "$RC" = 0 ] && grep -qx 'capture: disabled (inside a git work tree)' <<<"$OUT"; then pass "status shows git work tree reason"; else fail "status git: $OUT"; fi

# L9. bin wrapper.
fresh_root
NROOT_SET; OUT="$(cd / && "$REPO_DIR/bin/warden-lesson" status 2>&1)"
if grep -qx "inbox: $NROOT" <<<"$OUT" && grep -qx 'records: 0' <<<"$OUT"; then pass "bin/warden-lesson status works from another folder"; else fail "bin wrapper: $OUT"; fi

# ---- Final-review fixes ----
# F1. status counts derived records.
fresh_root; mkdir -p "$ROOT/sessions"
{ for i in 1 2 3; do jfail "2026-10-01T00:00:0${i}Z" "pytest" "E boom" "u$i" ',"h":"abcd1234abcd1234"'; done
  echo '{"t":"edit","ts":"2026-10-01T00:00:04Z"}'; echo '{"t":"edit","ts":"2026-10-01T00:00:05Z"}'
  echo '{"t":"pass","ts":"2026-10-01T00:00:06Z","tool_use_id":"tp","h":"abcd1234abcd1234"}'; } > "$ROOT/sessions/a.jsonl"
WL add "one lesson" >/dev/null
WL status | grep -qx 'records: 2' && pass "status counts derived records (2)" || fail "status derived count: $(WL status)"

# F3. Fix-linking window.
H=',"h":"abcd1234abcd1234"'
PASSL='{"t":"pass","ts":"2026-10-01T00:00:09Z","tool_use_id":"tp","h":"abcd1234abcd1234"}'
EDITL='{"t":"edit","ts":"2026-10-01T00:00:05Z"}'
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" pytest "E boom" u1 "$H"; echo "$EDITL"; jfail "2026-10-01T00:00:03Z" pytest "E boom" u2 "$H"; echo "$EDITL"; echo "$PASSL"; } > "$ROOT/sessions/a.jsonl"
WL list --json | jq1 'r=rs[0]; assert r["fixed"] is True and r["edits"]==1 and r["count"]==2, r' && pass "edits counted only after the last fail" || fail "window (a)"
fresh_root; mkdir -p "$ROOT/sessions"
{ jfail "2026-10-01T00:00:01Z" pytest "E boom" u1 "$H"; echo "$PASSL"; jfail "2026-10-01T00:00:10Z" pytest "E boom" u2 "$H"; } > "$ROOT/sessions/a.jsonl"
WL list --json | jq1 'assert rs[0]["fixed"] is False, rs' && pass "a pass before the last fail does not fix" || fail "window (b)"
fresh_root; mkdir -p "$ROOT/sessions"
{ echo "$EDITL"; echo "$EDITL"; jfail "2026-10-01T00:00:06Z" pytest "E boom" u1 "$H"; echo "$PASSL"; } > "$ROOT/sessions/a.jsonl"
WL list --json | jq1 'r=rs[0]; assert r["fixed"] is True and r["edits"]==0, r' && pass "edits before the fail are not counted" || fail "window (c)"

# F2. Production hook command from hooks.json.
HOOKS_JSON="$(dirname "$(dirname "$SCRIPT")")/hooks/hooks.json"
PLUGIN_DIR="$(dirname "$(dirname "$SCRIPT")")"
PCMD="$(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for ev in d["hooks"].values() for g in ev for h in g["hooks"] if "warden-lesson" in h["command"]]
assert len(cmds) == 2 and len(set(cmds)) == 1, cmds
print(cmds[0])' "$HOOKS_JSON")"
prod_hook() { CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash -c "$PCMD"; }
fresh_root
OUT="$(printf '%s' "$(fail_payload 'pytest -q' $'Exit code 1\nE   AssertionError: x')" | prod_hook 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(jl t)" = fail ]; then pass "production hook command records a fail"; else fail "prod command: rc=$RC out='$OUT' cmd=$PCMD"; fi
fresh_root
OUT="$(WARDEN_LESSON_OFF=1 prod_hook </dev/null 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$ROOT" ]; then pass "production command honours the off switch"; else fail "prod off switch"; fi
fresh_root
MEDP="$(python3 -I -c '
import subprocess, sys, time, statistics, os
env = dict(os.environ, CLAUDE_PLUGIN_ROOT=sys.argv[3])
ts = []
for _ in range(20):
    t = time.perf_counter()
    subprocess.run(["bash", "-c", sys.argv[1]], input=sys.argv[2], text=True, capture_output=True, env=env)
    ts.append((time.perf_counter() - t) * 1000)
print("%.1f" % statistics.median(ts))' "$PCMD" "$FP" "$PLUGIN_DIR")"
echo "  median production hook time: ${MEDP} ms"
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 50 else 1)' "$MEDP"; then pass "median of 20 production hook runs is under 50 ms ($MEDP ms)"; else fail "production median $MEDP ms"; fi

# ---- Capture quality (REQ-2.1, REQ-2.3, REQ-2.7, REQ-3.1, REQ-3.2). Every fixture is synthetic. ----
# Q1. Lines that start like an error win over the keyword-anywhere text around them.
if py '
CASES = [
    ("ls *.ts", "(eval):1: no matches found: *.ts", "(eval):1: no matches found: *.ts"),
    ("ls nope", "ls: nope: No such file or directory", "ls: nope: No such file or directory"),
    ("make x", "a plan line about a failing job\nmake: *** [x] Error 2", "make: *** [x] Error 2"),
    ("git push", "the failed step\nfatal: not a git repository", "fatal: not a git repository"),
    ("node a.js", "this cannot be the line\nError: boom", "Error: boom"),
    ("cargo build", "not this denied line\nerror[E0382]: use of moved value", "error[E0382]: use of moved value"),
    ("pytest -q", "tests/a.py F\nFAILED tests/a.py::t - boom", "FAILED tests<path>::t - boom"),
    ("pytest -q", "E   assert 1 == 2\nFAILED tests/a.py::t", "E   assert 1 == 2"),
    ("python3 a.py", "Traceback (most recent call last):\n  File \"a.py\", line 1, in <module>\n    fail_now()\nValueError: bad value", "ValueError: bad value"),
    ("python3 a.py", "Traceback (most recent call last):\n  File \"a.py\", line 1, in <module>\npkg.Stop: halted", "pkg.Stop: halted"),
    ("make build", "Step 3 fixes the failing import\nThe docstring says it cannot fail\nbuild stopped", "build stopped"),
    ("pytest -q; echo done", "1 failed, 45 passed in 0.21s\ndone", "1 failed, 45 passed in 0.21s"),
    ("pytest -q | tail -3", "45 tests ran\nlast line", "last line"),
]
for cmd, out, want in CASES:
    got = wl.signature("Exit code 1\n" + out, cmd)
    assert got == want, (cmd, got, want)
'; then pass "signature prefers lines that start like an error, then the last line"; else fail "signature selection wrong"; fi

# Q2. File content never becomes a signature, even when the line holds an error word.
AD="We need a developer who cannot stop learning and never failed a client"
LSL="-rw-r--r--  1 exampleuser  staff  120 Oct  1 12:00 notes.md"
DOC='"""Raise an error when the file is not found."""'
PLAN="Error: this plan line only looks like an error"
if py '
ad, lsl, doc, plan = sys.argv[1:5]
CMDS = ["cat job.txt", "head -40 job.txt", "tail -5 job.txt", "sed -n 1,40p a.py", "ls -l", "cd x && ls -l",
        "cat job.txt | grep developer", "git log -3", "git show HEAD", "echo done", "awk 1 job.txt", "rg x job.txt",
        "pytest -q; cat job.txt | tail -3" ]
for cmd in CMDS[:-1]:
    for line in (ad, lsl, doc, plan, "E   looks like pytest", "FAILED the interview round", "1 failed, 2 passed"):
        got = wl.signature("Exit code 1\n" + line + "\nplain tail line", cmd)
        assert got == "", (cmd, line, got)
got = wl.signature("Exit code 1\n" + ad, "pytest -q; cat job.txt | tail -3")
assert got == "", got
for inline in ("python3 - <<\x27EOF\x27\nprint(open(\x27a\x27).read())\nEOF", "python3 -c \"print(1)\"", "node -e \"x\""):
    got = wl.signature("Exit code 1\n" + ad, inline)
    assert got == "", (inline, got)
got = wl.signature("Exit code 1\nTraceback (most recent call last):\n  File \"a\", line 1\nKeyError: \x27k\x27", "python3 - <<EOF\nx\nEOF")
assert got == "KeyError: \x27k\x27", got
got = wl.signature("Exit code 1\n" + ad + "\ncat: missing.txt: No such file or directory", "cat job.txt missing.txt")
assert got == "cat: missing.txt: No such file or directory", got
got = wl.signature("Exit code 128\n" + ad + "\nfatal: bad revision", "git log nope")
assert got == "fatal: bad revision", got
' "$AD" "$LSL" "$DOC" "$PLAN"; then pass "file-content lines never become signatures"; else fail "file content became a signature"; fi
fresh_root
run_hook "$(fail_payload 'cat job.txt' $'Exit code 1\nCONTENTMARKER senior role, cannot be remote\nCONTENTMARKER failed applicants may reapply')"
if [ "$(nlines)" = 1 ] && [ -z "$(jl sig)" ] && ! grep -rq CONTENTMARKER "$ROOT"; then pass "hook writes no file content to the inbox"; else fail "file content reached the inbox: $(cat "$(sess)" 2>/dev/null)"; fi

# Q3. cmd survives heredocs and quoted scripts; a command that does not parse is marked.
if py '
CASES = [
    ("cd x && python3 - <<\x27EOF\x27\np = \"a\"\nprint(\"unbalanced \x27 quote\")\nlive_ping\"\nEOF", "python3"),
    ("cat > a.txt <<EOF\ndon\x27t split\nEOF\nmake build", "make build"),
    ("python3 -c \"import x\nlive_ping\"", "python3"),
    ("node -e \"console.log(typeof x); y\"", "node"),
    ("bash -c \"a; b | c\"", "bash"),
    ("A=\x27b c\x27 make build", "make build"),
    ("pytest -q; echo done", "pytest"),
    ("uv run --locked pytest -q | tail -3", "pytest"),
    ("echo \"unterminated", "unparsed"),
    ("", ""),
]
for cmd, want in CASES:
    got = wl.cmd_name(cmd)
    assert got == want, (cmd, got, want)
assert not wl.is_test_like("echo \"pytest")
got = wl.signature("Exit code 1\nsome file line\nzsh:1: parse error near x", "echo \"unterminated")
assert got == "zsh:1: parse error near x", got
assert wl.signature("Exit code 1\nsome file line", "echo \"unterminated") == ""
'; then pass "cmd parses heredocs and quoted scripts and marks parse failures"; else fail "cmd parsing wrong"; fi

# Q4. A test inside a chain is test-like; a mention of a test is not.
if py '
for c in ["pytest -q 2>&1 | tail -5", "cd x && npm test -- --maxWorkers=4 2>&1 | grep y", "pytest -q; echo done",
          "uv run --locked pytest -q tests/a.py | head", ".venv/bin/python -m pytest", "python3.12 -m pytest",
          "npx vitest run x", "timeout 60 pytest", "FOO=\x27a b\x27 pytest", "npm run test", "npm run test:unit",
          "make check >/dev/null 2>&1; echo $?", "python3 - <<\x27EOF\x27\nprint(1)\nEOF\npytest -q", "bash -x tests/a.sh | tail"]:
    assert wl.is_test_like(c), c
for c in ["sed -n 1,5p tests/a.sh", "cat tests/a.sh", "git add tests/a.sh", "grep pytest a.txt", "echo \x27pytest | tail\x27",
          "python3 -c \"import pytest\"", "cat > a <<EOF\npytest -q\nEOF", "npm install"]:
    assert not wl.is_test_like(c), c
'; then pass "test-like finds a test anywhere in a chain and ignores mentions"; else fail "chain test-like wrong"; fi

# Q5. Fix links survive output decoration; a hidden failure never counts as a pass.
linked() { WL list --json | jq1 'assert rs[0]["fixed"] is '"$1"', rs'; }
plines() { cat "$(sess)" 2>/dev/null | grep -c '"t":"pass"'; }
fresh_root
run_hook "$(fail_payload 'pytest -q 2>&1 | tail -5; echo done' $'Exit code 1\nFAILED tests/a.py::t')"
run_hook "$(payload PostToolUse Edit x '')"
run_hook "$(PAYLOAD_STDOUT=$'46 passed in 0.21s' payload PostToolUse Bash 'pytest -q 2>&1 | tail -3' '')"
if linked True && WL list --json | jq1 'assert rs[0]["edits"]==1 and rs[0]["cmd"]=="pytest", rs'; then pass "piped rerun with a pass summary links the fix"; else fail "decorated rerun did not link: $(cat "$(sess)")"; fi
fresh_root
run_hook "$(fail_payload 'pytest -q; echo done' $'Exit code 1\nFAILED tests/a.py::t')"
run_hook "$(PAYLOAD_STDOUT=$'1 failed, 45 passed in 0.21s' payload PostToolUse Bash 'pytest -q | tail -3' '')"
[ "$(plines)" = 0 ] && linked False && pass "piped run with a failure summary writes no pass" || fail "hidden failure wrote a pass: $(cat "$(sess)")"
fresh_root
run_hook "$(payload PostToolUse Bash 'pytest -q 2>&1 | grep FAILED' '')"
run_hook "$(PAYLOAD_STDOUT=$'all good' payload PostToolUse Bash 'pytest -q; echo done' '')"
[ "$(plines)" = 0 ] && pass "hidden exit with no pass summary writes no pass" || fail "unknown result wrote a pass"
fresh_root
run_hook "$(payload PostToolUse Bash 'pytest -q && echo ok' '')"
run_hook "$(payload PostToolUse Bash 'set -o pipefail; pytest -q | tail -3' '')"
run_hook "$(payload PostToolUse Bash 'cd sub && pytest -q' '')"
[ "$(plines)" = 3 ] && pass "visible exit status writes a pass without a summary" || fail "visible exit: $(cat "$(sess)" 2>/dev/null)"
if py '
ha = wl.test_hash("cd a && pytest -q", "/r")
assert ha != wl.test_hash("cd b && pytest -q", "/r")
assert ha == wl.test_hash("pytest -q 2>&1 | tail -3", "/r/a")
assert wl.test_hash("ls", "/r") is None
assert wl.test_hash("pytest -q", "/r") != wl.test_hash("pytest -q tests/a.py", "/r")
'; then pass "hash uses the test and its folder, not the decoration"; else fail "test hash wrong"; fi
fresh_root
run_hook "$(fail_payload 'pytest -q' $'Exit code 1\nFAILED tests/a.py::t')"
run_hook "$(payload PostToolUse Bash 'pytest -q tests/a.py' '')"
linked False && pass "a narrower rerun stays unlinked (known limit)" || fail "narrower rerun linked"

harness_exit
