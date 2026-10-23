#!/usr/bin/env bash
# REQ-6, REQ-7. The lesson store, the secret scrub and retention.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SCRIPT="$REPO_DIR/plugins/warden/scripts/warden-lesson"
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

harness_exit
