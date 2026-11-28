#!/usr/bin/env bash
# Offline test for lib/suite_compare.py. Hand-written summaries and a temp git repository.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
CMP="$HERE/../lib/suite_compare.py"
export PYTHONDONTWRITEBYTECODE=1

T=$(mktemp -d "${TMPDIR:-/tmp}/warden-compare-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# Temp repository: c1 base, c2 changes plugins/, c3 changes docs only.
R="$T/repo"; mkdir -p "$R/plugins" "$R/docs"
git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/plugins/a"; echo a > "$R/docs/a"
git -C "$R" add -A; git -C "$R" commit -qm c1; C1=$(git -C "$R" rev-parse HEAD)
echo b > "$R/plugins/a"; git -C "$R" commit -qam c2; C2=$(git -C "$R" rev-parse HEAD)
echo b > "$R/docs/a"; git -C "$R" commit -qam c3; C3=$(git -C "$R" rev-parse HEAD)
BOGUS=$(printf 'f%.0s' $(seq 1 40))

# mk FOLDER ID DATE SHA CLI MODEL CASES_JSON
mk() {
  mkdir -p "$1"
  python3 -I -c '
import json, sys
f, i, d, sha, cli, model, cases = sys.argv[1:8]
json.dump({"schema": 1, "id": i, "date": d, "sha": sha, "cli_version": cli, "cli_version_raw": cli,
           "model": model, "graphify_version": "g", "fixture_hash": "h", "runs": 5,
           "cases": json.loads(cases)}, open(f + "/" + d[:10] + "-" + i + ".json", "w"))' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
# ent CASE ARM MODEL COUNT ERRORED RESULT
ent() {
  printf '{"case":"%s","arm":"%s","model":"%s","count":%s,"errored":%s,"runs":5,"rule":"at-least","threshold":4,"result":"%s"}' "$1" "$2" "$3" "$4" "$5" "$6"
}
# cmp FOLDER NEW -> OUT, ERR, RC
cmp() {
  python3 -I "$CMP" --folder "$1" --new "$2" --repo "$R" >"$T/o" 2>"$T/e"
  RC=$?; OUT=$(cat "$T/o"); ERR=$(cat "$T/e")
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
M=claude-opus-5-5
D1=2026-11-01T10:00:00Z; D2=2026-11-02T10:00:00Z; D3=2026-11-03T10:00:00Z

# T15
F="$T/t15"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 1 0 FAIL)]"
cmp "$F" bbbbbb
if [ $RC -eq 0 ] && printf '%s\n' "$OUT" | grep 'read-order' | grep -qF FLIPPED; then pass "T15 PASS to FAIL is FLIPPED"
else fail "T15 rc=$RC $OUT $ERR"; fi

# T16
F="$T/t16"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 4 0 PASS)]"
cmp "$F" bbbbbb
if [ $RC -eq 0 ] && has "5/5" && has "4/5" && ! has FLIPPED; then pass "T16 5/5 PASS to 4/5 PASS is not FLIPPED"
else fail "T16 rc=$RC $OUT $ERR"; fi

# T17
F="$T/t17"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 3 2 ERRORED)]"
cmp "$F" bbbbbb
if has "not comparable (2 errored)" && has "rerun: warden-lesson suite --case read-order" && ! has FLIPPED; then
  pass "T17 ERRORED is not comparable, with the rerun hint"
else fail "T17 $OUT $ERR"; fi

# T18
F="$T/t18"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 3 2 ERRORED),$(ent other main $M 5 0 PASS)]"
mk "$F" cccccc $D3 $C2 2.1.2 $M "[$(ent read-order main $M 5 0 PASS)]"
cmp "$F" bbbbbb
if printf '%s\n' "$OUT" | grep 'read-order' | grep -q 'cccccc' && printf '%s\n' "$OUT" | grep 'read-order' | grep -qF PASS \
   && ! has "not comparable"; then pass "T18 rerun PASS row names the rerun id"
else fail "T18 $OUT $ERR"; fi

# T19
F="$T/t19"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 5 0 PASS)]"
cmp "$F" bbbbbb
if has "plugin files: changed between ${C1:0:7} and ${C2:0:7}"; then pass "T19 change under plugins/ is changed"
else fail "T19a $OUT $ERR"; fi
F="$T/t19b"; mk "$F" aaaaaa $D1 $C2 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C3 2.1.2 $M "[$(ent read-order main $M 5 0 PASS)]"
cmp "$F" bbbbbb
if has "plugin files: unchanged"; then pass "T19 change outside plugins/ is unchanged"
else fail "T19b $OUT $ERR"; fi

# T20
F="$T/t20"; mk "$F" aaaaaa $D1 $BOGUS 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 5 0 PASS)]"
cmp "$F" bbbbbb
if has "plugin files: unknown (${BOGUS:0:7} not found)"; then pass "T20 unknown old SHA"
else fail "T20 $OUT $ERR"; fi

# T21
F="$T/t21"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
cmp "$F" aaaaaa
if [ $RC -eq 0 ] && has "no earlier suite record with different pins"; then pass "T21 single summary"
else fail "T21 rc=$RC $OUT $ERR"; fi

# T22
F="$T/t22"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS)]"
mk "$F" bbbbbb $D2 $C2 2.1.2 $M "[$(ent read-order main $M 1 0 FAIL)]"
echo '{broken' > "$F/2026-11-09-bad.json"
cmp "$F" bbbbbb
if printf '%s' "$ERR" | grep -qF "skipped unreadable summary: " && printf '%s' "$ERR" | grep -qF 2026-11-09-bad.json && has FLIPPED; then
  pass "T22 broken summary skipped, good ones compared"
else fail "T22 $OUT $ERR"; fi

# T23
F="$T/t23"; mk "$F" aaaaaa $D1 $C1 2.1.1 $M "[$(ent read-order main $M 5 0 PASS),$(ent read-order ab claude-sonnet-5-5 1 0 FAIL)]"
cmp "$F" aaaaaa
if has "A/B: claude-sonnet-5-5 against $M" && printf '%s\n' "$OUT" | sed -n '/^A\/B:/,$p' | grep -qF FLIPPED; then
  pass "T23 A/B block with FLIPPED"
else fail "T23 $OUT $ERR"; fi

# usage
python3 -I "$CMP" --folder "$T/t15" --repo "$R" >/dev/null 2>&1; rc=$?
python3 -I "$CMP" --folder "$T/t15" --new nosuch --repo "$R" >/dev/null 2>&1; rc2=$?
if [ $rc -eq 2 ] && [ $rc2 -eq 2 ]; then pass "usage: missing or unknown --new exits 2"
else fail "usage rc=$rc rc2=$rc2"; fi

[ ! -d "$HERE/../lib/__pycache__" ] || fail "suite_compare.py left a __pycache__"
harness_exit
