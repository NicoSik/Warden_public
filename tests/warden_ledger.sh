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

# ---- Task 2: matching, the after-fix rule, the report decoration, mark match output ----
export TZ=Europe/Oslo
# sfail SESSION TS CMD SIG [REPO]: one fail line. sline SESSION JSON: a raw line.
sfail() {
  printf '{"t":"fail","ts":"%s","src":"hook","cmd":"%s","exit":1,"sig":"%s","session_id":"%s","transcript_path":"","tool_use_id":"u","repo":"%s","branch":"b","commit":"c"}\n' \
    "$2" "$3" "$4" "$1" "${5:-r}" >> "$ROOT/sessions/$1.jsonl"
}
sline() { echo "$2" >> "$ROOT/sessions/$1.jsonl"; }
sroot() { fresh_root; mkdir -p "$ROOT/sessions"; }

# T7. mark prints what the regex matches.
sroot
for i in 1 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "(eval):$i: ==== not found"; done
sfail s4 2026-11-14T10:00:00Z python "KeyError: 'x'"
OUT="$(WL mark w open --match '^\(eval\):N: \S+ not found$')"
case "$OUT" in *"  matches: 1 signatures, 3 sessions, 0 after fix"*) pass "mark prints the match counts";; *) fail "mark match counts: $OUT";; esac
OUT="$(WL mark k open --match KeyError)"
case "$OUT" in *"  matches: 1 signatures, 1 sessions, 0 after fix"*) pass "hidden rows count in the mark output";; *) fail "mark hidden count: $OUT";; esac
sroot
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sfail s1 2026-11-11T10:00:00Z make "dup-$(printf '%c' $(printf "\\$(printf %o $((96+i)))")): bad"; done
OUT="$(WL mark many open --match 'bad$')"
N="$(printf '%s\n' "$OUT" | grep -c '^  --  ')"
case "$OUT" in *"matches: 12 signatures"*"  +2 more"*) [ "$N" = 10 ] && pass "mark prints 10 rows and +2 more" || fail "mark printed $N rows";; *) fail "mark overflow: $OUT";; esac
sroot
for i in 1 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "(eval):$i: ==== not found"; done
WL mark w open --match '^\(eval\):N: \S+ not found$' >/dev/null
OUT="$(WL mark x open --match 'not found')"
case "$OUT" in *"mark: warning, also matched by w"*) pass "mark warns about an overlap";; *) fail "mark overlap: $OUT";; esac

# T10. No ledger, and an empty ledger, leave the report byte for byte as before.
git -C "$REPO_DIR" show 777adff:plugins/warden/scripts/warden-lesson > "$HARNESS_TMP/ref"
sroot
sfail s1 2026-11-11T10:00:00Z git "fatal: not a git repository" alpha
sfail s2 2026-11-12T10:00:00Z git "fatal: not a git repository" beta
sfail s1 2026-11-11T10:00:00Z python "KeyError: 'k'"
sline s1 '{"t":"nudge","ts":"2026-11-11T10:00:00Z","repo":"r","trigger":"skill","via":"direct","word":"ask"}'
same_as_ref() {
  for a in "" "--all"; do
    local want got
    want="$(python3 -I "$HARNESS_TMP/ref" report $a 2>&1)"; got="$(WL report $a 2>&1)"
    [ "$want" = "$got" ] || return 1
  done
}
same_as_ref && pass "report without a ledger matches the old script" || fail "no-ledger report differs"
: > "$ROOT/ledger.jsonl"
same_as_ref && pass "report with an empty ledger matches the old script" || fail "empty-ledger report differs"
if py 'import sys; wl.main(["report"]); assert "warden_ledger" not in sys.modules' >/dev/null; then pass "an empty ledger does not load the module"; else fail "module loaded for an empty ledger"; fi

# T11. A fixed entry with an after-fix session.
sroot
sfail s1 2026-11-11T10:00:00Z python "KeyError: 'x'"
WL mark ke fixed --pr 11 --fixed-on 2026-11-10 --match KeyError >/dev/null
OUT="$(WL report)"
case "$OUT" in "Fixed but recurring:"*) pass "report starts with the recurring section";; *) fail "recurring start: $OUT";; esac
case "$OUT" in *"ke  fixed #11 2026-11-10  1 session after fix"*) pass "block header";; *) fail "block header: $OUT";; esac
printf '%s\n' "$OUT" | grep -q "^      --  s1  x1  r  python  KeyError: 'x'$" && pass "row sits indented under the header" || fail "block row: $OUT"
[ "$(printf '%s\n' "$OUT" | grep -c "KeyError")" = 1 ] && pass "the row is not in the main list" || fail "row repeated: $OUT"
case "$OUT" in *"hidden: 0") pass "the one-off count is one lower";; *) fail "hidden count: $OUT";; esac

# T12. A session that began on the fix day is not after the fix.
sroot
sline s1 '{"t":"edit","ts":"2026-11-10T20:00:00Z"}'
sfail s1 2026-11-11T09:00:00Z python "KeyError: 'x'"
WL mark ke fixed --pr 11 --fixed-on 2026-11-10 --match KeyError >/dev/null
OUT="$(WL report --all)"
case "$OUT" in *"Fixed but recurring:"*) fail "same-day session counted: $OUT";; *) pass "no recurring section for a same-day session";; esac
case "$OUT" in *"hidden(one-off exception)  ledger(ke:fixed)"*|*"ledger(ke:fixed)  hidden(one-off exception)"*) pass "the row is tagged fixed";; *) fail "tag: $OUT";; esac

# T13. Nudge entries.
sroot
sline n1 '{"t":"nudge","ts":"2026-11-26T10:00:00Z","repo":"r","trigger":"skill","via":"direct","word":"ask"}'
WL mark setup-check-miss fixed --nudge --fixed-on 2026-11-25 >/dev/null
OUT="$(WL report)"
case "$OUT" in "Fixed but recurring:"*"setup-check-miss  fixed 2026-11-25  1 session after fix"*"      2026-11-26  r  skill  direct  ask  no setup-call"*) pass "nudge block shows";; *) fail "nudge block: $OUT";; esac
sline n1 '{"t":"setup-call","ts":"2026-11-26T10:05:00Z","repo":"r"}'
OUT="$(WL report)"
case "$OUT" in *"Fixed but recurring:"*) fail "followed nudge still blocked: $OUT";; *) pass "a followed nudge leaves the block";; esac

# T14. Ignored, open and fixed decorations.
sroot
sfail s1 2026-11-11T10:00:00Z git "fatal: not a git repository" alpha
sfail s2 2026-11-12T10:00:00Z git "fatal: not a git repository" beta
sfail s3 2026-11-12T10:00:00Z make "boom"
WL mark ig ignored --note noise --match fatal >/dev/null
OUT="$(WL report)"
case "$OUT" in *"hidden: 1 ignored") pass "ignored is the last hidden reason";; *) fail "ignored footer: $OUT";; esac
printf '%s\n' "$OUT" | grep -q "not a git" && fail "ignored row shown" || pass "an ignored entry hides its row"
OUT="$(WL report --all)"
case "$OUT" in *"hidden(ignored)"*) pass "--all shows hidden(ignored)";; *) fail "--all: $OUT";; esac
WL mark op open --match boom >/dev/null
case "$(WL report)" in *"boom  ledger(op:open)"*) pass "an open entry tags its row";; *) fail "open tag: $(WL report)";; esac
WL mark op fixed --fixed-on 2026-11-20 >/dev/null
case "$(WL report)" in *"boom  ledger(op:fixed)"*) pass "a fixed entry with no after-fix session tags the row";; *) fail "fixed tag: $(WL report)";; esac

# T15. The later entry wins.
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
WL mark aa open --match boom >/dev/null
WL mark bb open --match 'boo' >/dev/null
case "$(WL report)" in *"ledger(bb:open)"*) pass "the entry written later supplies the tag";; *) fail "later wins: $(WL report)";; esac
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
WL mark bb open --match 'boo' >/dev/null
WL mark aa open --match boom >/dev/null
case "$(WL report)" in *"ledger(aa:open)"*) pass "the other order flips the tag";; *) fail "later wins 2: $(WL report)";; esac

# T16. A bad regex and an unreadable ledger.
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
WL mark ok open --match boom >/dev/null
echo '{"slug":"bad","kind":"sig","match":"(","status":"open","ts":"2026-11-26T10:00:00Z"}' >> "$ROOT/ledger.jsonl"
OUT="$(WL report)"; RC=$?
[ "$RC" = 0 ] && [ "${OUT##*$'\n'}" = "ledger: 1 entries skipped (bad regex: bad)" ] && pass "a bad regex is skipped and reported" || fail "bad regex: rc=$RC $OUT"
chmod 000 "$ROOT/ledger.jsonl"
OUT="$(WL report 2>&1)"; RC=$?
chmod 600 "$ROOT/ledger.jsonl"
[ "$RC" = 0 ] && [ "${OUT##*$'\n'}" = "ledger: unreadable" ] && pass "an unreadable ledger is reported" || fail "unreadable: rc=$RC $OUT"

# T16b. An entry with no status or an unknown kind is skipped; nothing crashes.
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
echo '{"slug":"nostat","kind":"sig","match":"boom","ts":"2026-11-26T10:00:00Z"}' >> "$ROOT/ledger.jsonl"
echo '{"slug":"other","kind":"other","status":"open","ts":"2026-11-26T10:00:00Z"}' >> "$ROOT/ledger.jsonl"
OUT="$(WL report 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "${OUT##*$'\n'}" = "ledger: 2 entries skipped (invalid: nostat, other)" ] && pass "invalid entries are skipped and named in the footer" || fail "invalid entries: rc=$RC $OUT"
echo '{"slug":"bad","kind":"sig","match":"(","status":"open","ts":"2026-11-26T10:00:00Z"}' >> "$ROOT/ledger.jsonl"
OUT="$(WL report 2>&1)"
case "$OUT" in *"ledger: 1 entries skipped (bad regex: bad)"*"ledger: 2 entries skipped (invalid: nostat, other)"*|*"ledger: 2 entries skipped (invalid: nostat, other)"*"ledger: 1 entries skipped (bad regex: bad)"*) pass "both skip footers print";; *) fail "both footers: $OUT";; esac
WL mark fine open --match boom >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && pass "mark succeeds beside invalid entries" || fail "mark beside invalid: rc=$RC"
WL weekly >/dev/null 2>&1; RC=$?
[ -f "$ROOT/weekly/last-run" ] && pass "weekly writes last-run beside invalid entries" || fail "weekly beside invalid: rc=$RC"

# ---- Task 3: weekly and the weekly: status line ----
export WARDEN_NOW=2026-11-30T09:15:00
oslines() { grep -c '^osascript' "$WARDEN_STUB_LOG"; }
clearlog() { : > "$WARDEN_STUB_LOG"; }
lastrun_has() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); '"$2" "$ROOT/weekly/last-run"; }

# T17. Nothing to report: the report file and last-run are written, no notification.
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
clearlog
WL weekly; RC=$?
if [ $RC -eq 0 ] && [ -f "$ROOT/weekly/report-2026-11-30.txt" ] && lastrun_has x 'assert d["notified"] is False and d["recurring"]==0 and d["unacknowledged"]==0 and "error" not in d' && [ "$(oslines)" = 0 ]; then pass "weekly with nothing to report writes files and stays quiet"; else fail "T17: rc $RC"; fi
[ "$(mode_of "$ROOT/weekly")" = 700 ] && pass "weekly folder has mode 700" || fail "weekly mode $(mode_of "$ROOT/weekly")"
[ "$(cat "$ROOT/weekly/report-2026-11-30.txt")" = "$(WL report)" ] && pass "the weekly file holds the report text" || fail "weekly file differs from report"

# T18. A recurring fixed entry notifies once, with counts and the path only.
sroot
sfail s1 2026-11-11T10:00:00Z python "KeyError: 'x'"
sfail s2 2026-11-12T10:00:00Z python "KeyError: 'y'"
WL mark ke fixed --pr 11 --fixed-on 2026-11-10 --match KeyError >/dev/null
clearlog
WL weekly; RC=$?
if [ $RC -eq 0 ] && [ "$(oslines)" = 1 ] && grep -q '1 fixed entry recurring, 0 flagged signatures without an entry\.' "$WARDEN_STUB_LOG" && grep -q 'report-2026-11-30\.txt' "$WARDEN_STUB_LOG" && ! grep -q 'KeyError' "$WARDEN_STUB_LOG" && grep -q "^osascript .*Warden lessons" "$WARDEN_STUB_LOG" && lastrun_has x 'assert d["notified"] is True and d["recurring"]==1'; then pass "a recurring entry sends one notification with counts"; else fail "T18: rc $RC log: $(cat "$WARDEN_STUB_LOG")"; fi

# T18b. A session before fixed_on does not recur.
sroot
sfail s1 2026-11-11T10:00:00Z python "KeyError: 'x'"
WL mark ke fixed --fixed-on 2026-11-20 --match KeyError >/dev/null
clearlog
WL weekly
[ "$(oslines)" = 0 ] && pass "a session before the fix gives no notification" || fail "T18b: $(cat "$WARDEN_STUB_LOG")"

# T19. A flagged signature without an entry notifies until it is marked.
sroot
for i in 1 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "(eval):$i: ==== not found"; done
clearlog
WL weekly
if [ "$(oslines)" = 1 ] && grep -q '1 flagged signature without an entry' "$WARDEN_STUB_LOG" && lastrun_has x 'assert d["unacknowledged"]==1'; then pass "a flagged signature notifies"; else fail "T19: $(cat "$WARDEN_STUB_LOG")"; fi
WL mark w open --match '^\(eval\):N: \S+ not found$' >/dev/null
clearlog
WL weekly
[ "$(oslines)" = 0 ] && pass "marking the signature stops the notification" || fail "T19 after mark: $(cat "$WARDEN_STUB_LOG")"

# T19b. A flagged row hidden as no signature is not unacknowledged.
sroot
for i in 1 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "" "repo$i"; done
clearlog
OUT="$(WL report)"
WL weekly
if case "$OUT" in *"hidden: 1 no signature"*) true;; *) false;; esac && [ "$(oslines)" = 0 ] && lastrun_has x 'assert d["unacknowledged"]==0'; then pass "a no-signature row is not counted as unacknowledged"; else fail "T19b: $OUT $(cat "$ROOT/weekly/last-run")"; fi

# T20. Retention keeps the 12 newest reports and touches nothing else.
sroot
mkdir -p "$ROOT/weekly"; chmod 700 "$ROOT/weekly"
echo '{}' > "$ROOT/weekly/schedule.json"; : > "$ROOT/weekly/launchd.err"
for d in $(python3 -I -c 'import datetime
d=datetime.date(2026,11,2)
print(*[(d+datetime.timedelta(7*i)).isoformat() for i in range(14)])'); do
  WARDEN_NOW="${d}T09:15:00" WL weekly
done
N="$(ls "$ROOT/weekly" | grep -c '^report-.*\.txt$')"
if [ "$N" = 12 ] && [ ! -e "$ROOT/weekly/report-2026-11-02.txt" ] && [ ! -e "$ROOT/weekly/report-2026-11-09.txt" ] && [ -e "$ROOT/weekly/report-2026-11-16.txt" ] && [ -e "$ROOT/weekly/report-2027-02-01.txt" ] && [ -f "$ROOT/weekly/last-run" ] && [ -f "$ROOT/weekly/schedule.json" ] && [ -f "$ROOT/weekly/launchd.err" ]; then pass "12 reports remain; other weekly files survive"; else fail "T20: $N reports: $(ls "$ROOT/weekly")"; fi

# T21. A failed notification exits 1 and is recorded.
sroot
for i in 1 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "(eval):$i: ==== not found"; done
clearlog
WARDEN_STUB_OSASCRIPT_EXIT=1 WL weekly; RC=$?
if [ $RC -eq 1 ] && lastrun_has x 'assert d["error"]=="notify failed: 1" and d["notified"] is False' && [ -f "$ROOT/weekly/report-2026-11-30.txt" ]; then pass "a failed notification exits 1 and is recorded"; else fail "T21: rc $RC $(cat "$ROOT/weekly/last-run")"; fi
NOOSA="$(mktemp -d "$HARNESS_TMP/nobin.XXXXXX")"; ln -s "$(command -v python3)" "$NOOSA/python3"
OUT="$(PATH="$NOOSA" WL weekly 2>&1)"; RC=$?
if [ $RC -eq 1 ] && lastrun_has x 'assert d["error"]=="notify failed: 127"'; then pass "no osascript on PATH gives 127"; else fail "127: rc $RC $(cat "$ROOT/weekly/last-run")"; fi

# T26 (weekly part). The weekly: line is line 5; the first four lines stay as before.
sroot
sfail s1 2026-11-11T10:00:00Z make "boom"
OUT="$(WL status)"
[ "$(printf '%s\n' "$OUT" | sed -n 5p)" = "weekly: never run" ] && pass "status says weekly: never run" || fail "never run: $OUT"
[ "$(printf '%s\n' "$OUT" | head -4)" = "$(python3 -I "$HARNESS_TMP/ref" status | head -4)" ] && pass "the first four status lines are unchanged" || fail "status head differs"
WL weekly
L="$(WL status | sed -n 5p)"
[ "$L" = "weekly: last run 2026-11-30 09:15, 0 recurring entries, 0 unacknowledged, not notified" ] && pass "status shows the last run" || fail "weekly line: '$L'"
L="$(WARDEN_NOW=2026-12-09T09:15:00 WL status | sed -n 5p)"
case "$L" in *" STALE") pass "a run 9 days old is STALE";; *) fail "stale: '$L'";; esac
L="$(WARDEN_NOW=2026-12-08T09:15:00 WL status | sed -n 5p)"
case "$L" in *STALE*) fail "8 days is not stale: '$L'";; *) pass "a run 8 days old is not stale";; esac
for i in 2 3; do sfail "s$i" "2026-11-1${i}T10:00:00Z" make "boom"; done
WARDEN_STUB_OSASCRIPT_EXIT=1 WL weekly >/dev/null
L="$(WL status | sed -n 5p)"
case "$L" in *"1 unacknowledged, not notified, error: notify failed: 1") pass "status shows the error";; *) fail "error line: '$L'";; esac
echo 'not json' > "$ROOT/weekly/last-run"
[ "$(WL status | sed -n 5p)" = "weekly: last-run unreadable" ] && pass "an unparseable last-run is reported" || fail "unreadable last-run"

# T9 (rest). weekly and status write nothing outside weekly/.
sroot
sfail s1 2026-11-11T10:00:00Z python "KeyError: 'x'"
WL mark ke fixed --fixed-on 2026-11-10 --match KeyError >/dev/null
outside() { (cd "$ROOT" && find . -type f -not -path './weekly/*' | sort | while read -r f; do shasum "$f"; done); }
BEFORE="$(outside)"
WL weekly; WL status >/dev/null
[ "$(outside)" = "$BEFORE" ] && pass "weekly and status leave everything outside weekly/ unchanged" || fail "weekly wrote outside weekly/"

# Schedule tests. Every one uses the stubs, a fake main checkout and a plist folder inside the harness.
schedsetup() {
  sroot
  rm -rf "$HARNESS_TMP/co" "$HARNESS_TMP/agents"
  mkdir -p "$HARNESS_TMP/co/.git" "$HARNESS_TMP/co/bin" "$HARNESS_TMP/co/plugins/warden/scripts" "$HOME/.claude"
  CO="$(cd -P "$HARNESS_TMP/co" && pwd)"
  cp "$REPO_DIR/plugins/warden/scripts/warden-lesson" "$REPO_DIR/plugins/warden/scripts/warden_ledger.py" "$CO/plugins/warden/scripts/"
  rm -f "$HOME/.claude/bin"; ln -s "$CO/bin" "$HOME/.claude/bin"
  CSCRIPT="$CO/plugins/warden/scripts/warden-lesson"
  PLIST="$HARNESS_TMP/agents/com.warden.lesson-weekly.plist"
  export WARDEN_LAUNCH_AGENTS="$HARNESS_TMP/agents" WARDEN_KICKSTART_WAIT=2
  export WARDEN_STUB_KICKSTART_CMD="python3 -I $CSCRIPT weekly"
  clearlog
}
plist_has() { python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); '"$2" "$PLIST"; }
CWL() { python3 -I "$CSCRIPT" "$@"; }

# T22. Install writes the plist, loads it and sends the test notification through launchd.
schedsetup
OUT="$(CWL schedule install < /dev/null 2>&1)"; RC=$?
PY3="$(command -v python3)"
if [ $RC -eq 0 ] && [ -f "$PLIST" ] && plist_has x 'assert d["ProgramArguments"]==["'"$PY3"'","-I","'"$CSCRIPT"'","weekly"], d["ProgramArguments"]; assert d["StartCalendarInterval"]=={"Weekday":1,"Hour":9,"Minute":15}; assert d["Label"]=="com.warden.lesson-weekly"; assert d["RunAtLoad"] is False'; then pass "install writes the plist"; else fail "T22 plist: rc $RC $OUT"; fi
UIDN="$(id -u)"
LOG="$(grep '^launchctl\|^osascript' "$WARDEN_STUB_LOG")"
if [ "$(printf '%s\n' "$LOG" | sed -n 1p)" = "launchctl bootout gui/$UIDN/com.warden.lesson-weekly" ] && [ "$(printf '%s\n' "$LOG" | sed -n 2p)" = "launchctl bootstrap gui/$UIDN $PLIST" ] && [ "$(printf '%s\n' "$LOG" | sed -n 3p)" = "launchctl kickstart gui/$UIDN/com.warden.lesson-weekly" ] && case "$(printf '%s\n' "$LOG" | sed -n 4p)" in osascript*"Test notification"*) true;; *) false;; esac && [ "$(oslines)" = 1 ] && [ "$(printf '%s\n' "$LOG" | wc -l | tr -d ' ')" = 4 ]; then pass "install runs bootout, bootstrap, kickstart, then one notification"; else fail "T22 log: $(cat "$WARDEN_STUB_LOG")"; fi
if [ ! -e "$ROOT/weekly/test-notify" ] && ! ls "$ROOT"/weekly/report-*.txt >/dev/null 2>&1 && [ ! -e "$ROOT/weekly/last-run" ]; then pass "the test run leaves no marker, report or last-run"; else fail "T22 files: $(ls "$ROOT/weekly")"; fi
clearlog
CWL schedule install < /dev/null >/dev/null 2>&1
if [ "$(ls "$HARNESS_TMP/agents" | wc -l | tr -d ' ')" = 1 ] && grep -q '^launchctl bootout' "$WARDEN_STUB_LOG"; then pass "a second install keeps one plist and boots out first"; else fail "T22 second install"; fi

# T22b. The agent never runs the test.
schedsetup
unset WARDEN_STUB_KICKSTART_CMD
START=$SECONDS
OUT="$(CWL schedule install < /dev/null 2>&1)"; RC=$?
ELAPSED=$((SECONDS - START))
if [ $RC -eq 1 ] && [ $ELAPSED -ge 2 ] && [ $ELAPSED -le 6 ] && case "$OUT" in *"did not run the test"*) true;; *) false;; esac && [ "$(oslines)" = 0 ] && [ ! -e "$ROOT/weekly/test-notify" ]; then pass "an agent that does not run exits 1 and removes the marker"; else fail "T22b: rc $RC after ${ELAPSED}s: $OUT"; fi

# T22d. A failed test notification is reported by install.
schedsetup
OUT="$(WARDEN_STUB_OSASCRIPT_EXIT=1 bash -c '(sleep 1; printf "y\n"; sleep 1) | script -q /dev/null python3 -I "'"$CSCRIPT"'" schedule install' 2>&1)"; RC=$?
if [ $RC -eq 1 ] || printf '%s' "$OUT" | grep -q 'test notification failed'; then
  if printf '%s' "$OUT" | grep -q 'test notification failed' && ! printf '%s' "$OUT" | grep -q 'Did you see' && [ ! -e "$ROOT/weekly/test-notify" ] && [ ! -e "$ROOT/weekly/schedule.json" ]; then pass "a failed test notification exits 1 and never asks"; else fail "T22d: rc $RC $OUT"; fi
else fail "T22d: rc $RC $OUT"; fi
schedsetup
OUT="$(WARDEN_STUB_OSASCRIPT_EXIT=1 CWL schedule install < /dev/null 2>&1)"; RC=$?
if [ $RC -eq 1 ] && case "$OUT" in *"test notification failed (notify failed: 1)"*) true;; *) false;; esac && [ ! -e "$ROOT/weekly/test-notify" ]; then pass "install without a terminal also reports the failure"; else fail "T22d b: rc $RC $OUT"; fi

# T22c. The marker decides the test mode by its age.
schedsetup
mkdir -p "$ROOT/weekly"; : > "$ROOT/weekly/test-notify"; touch -t 202001010000 "$ROOT/weekly/test-notify"
WL weekly >/dev/null
if ls "$ROOT"/weekly/report-*.txt >/dev/null 2>&1 && [ -f "$ROOT/weekly/last-run" ] && [ "$(oslines)" = 0 ] && [ ! -e "$ROOT/weekly/test-notify" ]; then pass "a stale marker is deleted and the weekly run goes on"; else fail "T22c stale: $(ls "$ROOT/weekly")"; fi
rm -f "$ROOT"/weekly/report-*.txt "$ROOT/weekly/last-run"; clearlog
: > "$ROOT/weekly/test-notify"
WL weekly >/dev/null; RC=$?
if [ $RC -eq 0 ] && [ "$(oslines)" = 1 ] && grep -q 'Test notification' "$WARDEN_STUB_LOG" && ! ls "$ROOT"/weekly/report-*.txt >/dev/null 2>&1 && [ ! -e "$ROOT/weekly/last-run" ] && [ ! -e "$ROOT/weekly/test-notify" ]; then pass "a fresh marker sends the test notification only"; else fail "T22c fresh: rc $RC $(ls "$ROOT/weekly")"; fi

# T23. Refusals.
schedsetup
rmdir "$CO/.git"; : > "$CO/.git"
OUT="$(CWL schedule install < /dev/null 2>&1)"; RC=$?
if [ $RC -eq 2 ] && case "$OUT" in *"is a git worktree"*) true;; *) false;; esac && [ ! -e "$PLIST" ]; then pass "install from a worktree is refused"; else fail "T23 worktree: rc $RC $OUT"; fi
schedsetup
rm -f "$HOME/.claude/bin"
OUT="$(CWL schedule install < /dev/null 2>&1)"; RC=$?
[ $RC -eq 2 ] && [ ! -e "$PLIST" ] && pass "install without ~/.claude/bin is refused" || fail "T23 no bin: rc $RC $OUT"

# T24. Confirmation.
schedsetup
OUT="$(CWL schedule install < /dev/null 2>&1)"
case "$OUT" in *"schedule confirm"*) pass "install without a terminal points to schedule confirm";; *) fail "T24 hint: $OUT";; esac
case "$(CWL status | grep '^schedule:')" in *"notification unconfirmed") pass "status shows unconfirmed";; *) fail "T24 status: $(CWL status)";; esac
CWL schedule confirm; RC=$?
L="$(CWL status | grep '^schedule:')"
[ $RC -eq 0 ] && [ "$L" = "schedule: installed, Monday 09:15" ] && pass "confirm makes status confirmed" || fail "T24 confirm: rc $RC '$L'"
schedsetup
(sleep 1; printf 'y\n'; sleep 1) | script -q /dev/null python3 -I "$CSCRIPT" schedule install >/dev/null 2>&1
grep -q '"confirmed"' "$ROOT/weekly/schedule.json" 2>/dev/null && pass "answering y at a terminal confirms" || fail "T24 tty: $(cat "$ROOT/weekly/schedule.json" 2>&1)"

# T25. Uninstall.
schedsetup
CWL schedule install < /dev/null >/dev/null 2>&1; clearlog
OUT="$(CWL schedule uninstall 2>&1)"; RC=$?
if [ $RC -eq 0 ] && [ ! -e "$PLIST" ] && grep -q '^launchctl bootout' "$WARDEN_STUB_LOG" && [ -d "$ROOT/weekly" ]; then pass "uninstall removes the plist and keeps weekly/"; else fail "T25: rc $RC $OUT"; fi
OUT="$(CWL schedule uninstall 2>&1)"; RC=$?
[ $RC -eq 0 ] && [ "$OUT" = "schedule: not installed" ] && pass "a second uninstall says not installed" || fail "T25b: rc $RC $OUT"

# T26 (schedule part).
schedsetup
[ "$(CWL status | grep '^schedule:')" = "schedule: not installed" ] && pass "status says schedule: not installed" || fail "T26 not installed"
CWL schedule install < /dev/null >/dev/null 2>&1
mv "$CSCRIPT" "$CSCRIPT.off"
case "$(WL status | grep '^schedule:')" in "schedule: broken (script missing: $CSCRIPT)") pass "status reports a missing script";; *) fail "T26 script: $(WL status | grep '^schedule:')";; esac
mv "$CSCRIPT.off" "$CSCRIPT"
python3 -I -c 'import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,"rb")); d["ProgramArguments"][0]="/nonexistent/python3"; plistlib.dump(d,open(p,"wb"))' "$PLIST"
case "$(CWL status | grep '^schedule:')" in "schedule: broken (interpreter missing: /nonexistent/python3)") pass "status reports a missing interpreter";; *) fail "T26 interp: $(CWL status | grep '^schedule:')";; esac

harness_teardown
exit $((FAILURES > 0))
