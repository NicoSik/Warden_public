#!/usr/bin/env bash
# REQ-10. The seed script writes four ledger entries once.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SEED="$REPO_DIR/docs/superpowers/changes/2026-11-lessons-ledger-weekly-report/seed.sh"
export WARDEN_LESSON="python3 -I $REPO_DIR/plugins/warden/scripts/warden-lesson"
export WARDEN_LESSON_ROOT="$HARNESS_TMP/inbox"
unset WARDEN_LESSON_OFF
mkdir -p "$WARDEN_LESSON_ROOT/sessions"
WL() { $WARDEN_LESSON "$@"; }
jfail() { printf '{"t":"fail","ts":"%s","src":"hook","cmd":"%s","exit":1,"sig":"%s","session_id":"s","transcript_path":"","tool_use_id":"%s","repo":"r","branch":"b","commit":"c"}\n' "$1" "$2" "$3" "$4"; }

jfail "2026-11-01T10:00:00Z" "echo ==== " "(eval):1: ==== not found" "u1" > "$WARDEN_LESSON_ROOT/sessions/z1.jsonl"
for i in 1 2 3; do
  jfail "2026-11-0${i}T11:00:00Z" "run" "Hedges<path> (may, might, could) are never flagged: confidence is content." "h$i" \
    > "$WARDEN_LESSON_ROOT/sessions/h$i.jsonl"
done

OUT="$(bash "$SEED" 2>&1)"; RC=$?
[ "$RC" = 0 ] && pass "seed.sh exits 0" || fail "seed.sh rc=$RC: $OUT"
if printf '%s\n' "$OUT" | grep -q 'matches: 1 signatures'; then pass "zsh-equals-word matches 1 signature"; else fail "no 'matches: 1 signatures': $OUT"; fi
if printf '%s\n' "$OUT" | grep -q 'matches: 0 signatures'; then pass "zsh-include-glob matches 0 signatures"; else fail "no 'matches: 0 signatures': $OUT"; fi

LIST="$(WL mark --list 2>&1)"
ok=1
for pair in zsh-equals-word:verified zsh-include-glob:verified setup-check-miss:fixed hedges-output-line:ignored; do
  printf '%s\n' "$LIST" | grep -q "^${pair%%:*} ${pair##*:} " || ok=0
done
[ "$ok" = 1 ] && pass "mark --list shows the four slugs with their statuses" || fail "list: $LIST"

REP="$(WL report 2>&1)"
if printf '%s\n' "$REP" | grep -q 'Hedges<path>'; then fail "report still lists the Hedges row: $REP"; else pass "report no longer lists the Hedges row"; fi
if printf '%s\n' "$REP" | grep -q '1 ignored'; then pass "report counts 1 ignored"; else fail "no '1 ignored': $REP"; fi

BEFORE="$(shasum "$WARDEN_LESSON_ROOT/ledger.jsonl")"
OUT2="$(bash "$SEED" 2>&1)"; RC2=$?
AFTER="$(shasum "$WARDEN_LESSON_ROOT/ledger.jsonl")"
[ "$RC2" = 0 ] && [ "$BEFORE" = "$AFTER" ] && pass "a second run leaves the ledger unchanged" || fail "second run rc=$RC2 $OUT2"

harness_teardown
exit $((FAILURES > 0))
