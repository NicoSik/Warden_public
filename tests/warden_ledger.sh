#!/usr/bin/env bash
# REQ-1, REQ-7, REQ-8. The ledger store, the lazy loader and warden-lesson mark.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SCRIPT="${WARDEN_LESSON_SCRIPT:-$REPO_DIR/plugins/warden/scripts/warden-lesson}"

# py CODE: run CODE with the script loaded as module `wl`. Extra args reach sys.argv[1:].
py() {
  local code="$1"; shift
  python3 -I -c '
import sys, importlib.machinery, importlib.util
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("wl", sys.argv[1])
spec = importlib.util.spec_from_loader("wl", loader)
wl = importlib.util.module_from_spec(spec)
sys.modules["wl"] = wl
loader.exec_module(wl)
code = sys.argv[2]
sys.argv[:] = ["wl"] + sys.argv[3:]
exec(code)
' "$SCRIPT" "$code" "$@"
}

fresh_root() { ROOT="$(mktemp -d "$HARNESS_TMP/root.XXXXXX")/inbox"; export WARDEN_LESSON_ROOT="$ROOT"; unset WARDEN_LESSON_OFF; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
WL() { python3 -I "$SCRIPT" "$@"; }
sums() { (cd "$ROOT" && find . -type f | sort | while read -r f; do shasum "$f"; done); }

# T1. The hook path never loads the ledger module.
fresh_root
if py '
import io, json, sys
p = {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "session_id": "s1", "cwd": "/tmp",
     "tool_input": {"command": "make"}, "error": "Exit code 1\nboom"}
payload = json.dumps(p)
sys.stdin = io.StringIO(payload)
wl._hook(None)
assert "warden_ledger" not in sys.modules, "loaded by _hook"
sys.stdin = io.StringIO(payload)
wl.main(["hook"])
assert "warden_ledger" not in sys.modules, "loaded by main hook"
sys.stdin = io.StringIO("{}")
wl.main(["nudge"])
assert "warden_ledger" not in sys.modules, "loaded by nudge"
m = wl._ledger()
assert "warden_ledger" in sys.modules and m.WL is wl and wl._ledger() is m
'; then pass "hook and nudge do not load the ledger module; _ledger() does, and caches"; else fail "lazy loader"; fi

# T2. The bin wrapper under python3 -I finds the module through a symlinked bin folder.
fresh_root
LINKDIR="$(mktemp -d "$HARNESS_TMP/link.XXXXXX")"
ln -s "$REPO_DIR/bin" "$LINKDIR/bin"
"$LINKDIR/bin/warden-lesson" mark a-b open --match x >/dev/null; RC1=$?
OUT="$("$LINKDIR/bin/warden-lesson" mark --list)"; RC2=$?
if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ "${OUT#a-b open}" != "$OUT" ]; then pass "wrapper through a symlink marks and lists"; else fail "wrapper: rc $RC1/$RC2, list '$OUT'"; fi

# Mode.
[ "$(mode_of "$ROOT/ledger.jsonl")" = 600 ] && pass "ledger has mode 600" || fail "ledger mode $(mode_of "$ROOT/ledger.jsonl")"

# T4. Latest line wins; missing flags are copied; history keeps every line.
fresh_root
WL mark s fixed --fixed-on 2026-11-10 --pr 11 --match a >/dev/null
WL mark s open >/dev/null
L="$(WL mark --list)"
[ "$L" = "s open #11 2026-11-10 sig" ] && pass "mark open shows open" || fail "list after open: '$L'"
WL mark s fixed >/dev/null
L="$(WL mark --list)"
case "$L" in "s fixed #11 2026-11-10 sig") pass "fixed again copies pr and fixed_on";; *) fail "list after fixed: '$L'";; esac
N="$(WL mark s --history | wc -l | tr -d ' ')"
[ "$N" = 3 ] && pass "history has 3 lines" || fail "history has $N lines"
WL mark nope --history >/dev/null 2>&1; [ $? -eq 2 ] && pass "history of an unknown slug exits 2" || fail "history unknown slug"

# T5. Copied fields survive a status change.
fresh_root
WL mark s open --match a --note n1 >/dev/null
WL mark s verified --fixed-on 2026-11-10 >/dev/null
if WL mark s --history | tail -1 | python3 -I -c 'import sys,json; d=json.loads(sys.stdin.read()); assert d["match"]=="a" and d["note"]=="n1" and d["status"]=="verified", d'; then pass "match and note are kept"; else fail "match or note lost"; fi
WL mark s open --nudge >/dev/null
WL mark --list | grep -q '^s open 2026-11-10 nudge n1$' && pass "--nudge changes a sig entry to a nudge" || fail "kind change: $(WL mark --list)"

# T6. Refusals exit 2 and leave the ledger byte for byte the same.
fresh_root
WL mark base open --match b >/dev/null
BEFORE="$(shasum "$ROOT/ledger.jsonl")"
refuse() {
  local label="$1"; shift
  WL mark "$@" >/dev/null 2>&1; local rc=$?
  if [ $rc -eq 2 ] && [ "$(shasum "$ROOT/ledger.jsonl")" = "$BEFORE" ]; then pass "refused: $label"; else fail "not refused (rc $rc): $label"; fi
}
refuse "status done" t done --match a
refuse "bad slug" Bad_Slug open --match a
refuse "new slug without match or nudge" t open
refuse "fixed without fixed_on" t fixed --match a
refuse "fixed_on 2026-13-01" t fixed --match a --fixed-on 2026-13-01
refuse "ignored without note" t ignored --match a
refuse "invalid regex" t open --match '('
refuse "secret-like run in match" t open --match "$(printf 'a%.0s' $(seq 1 41))"
refuse "cap changes the match" t open --match "$(printf 'ab %.0s' $(seq 1 150))" --note "$(printf 'n%.0s' $(seq 1 600))"

# A scrubbed note is kept and warned about.
OUT="$(WL mark nt open --match a --note "token=abcdef12345 here" 2>&1)"; RC=$?
if [ $RC -eq 0 ] && [ "${OUT#*note scrubbed or shortened}" != "$OUT" ] && ! WL mark --list | grep -q abcdef12345; then pass "scrubbed note is written with a warning"; else fail "note scrub: rc $RC out '$OUT'"; fi

# Capture disabled.
OUT="$(WARDEN_LESSON_OFF=1 WL mark off open --match a 2>&1)"; RC=$?
[ $RC -eq 1 ] && [ "${OUT#*capture is disabled}" != "$OUT" ] && pass "disabled capture exits 1" || fail "disabled capture: rc $RC '$OUT'"

# T8. Retention leaves the ledger alone.
fresh_root
WL mark a-1 open --match a >/dev/null; WL mark a-2 open --match b >/dev/null
mkdir -p "$ROOT/sessions"; : > "$ROOT/sessions/old.jsonl"
touch -t "$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '40 days ago' +%Y%m%d%H%M)" "$ROOT/ledger.jsonl" "$ROOT/sessions/old.jsonl"
rm -f "$ROOT/.retention"
BEFORE="$(shasum "$ROOT/ledger.jsonl")"
py 'wl.retention()'
if [ -f "$ROOT/ledger.jsonl" ] && [ "$(shasum "$ROOT/ledger.jsonl")" = "$BEFORE" ] && [ ! -e "$ROOT/sessions/old.jsonl" ]; then pass "retention keeps the old ledger (and removes the old session)"; else fail "retention touched the ledger"; fi

# T9 (part). report, status and mark --list write nothing.
BEFORE="$(sums)"
WL report >/dev/null 2>&1; WL status >/dev/null 2>&1; WL mark --list >/dev/null 2>&1
[ "$(sums)" = "$BEFORE" ] && pass "report, status and mark --list leave the inbox unchanged" || fail "inbox changed"

harness_teardown
exit $((FAILURES > 0))
