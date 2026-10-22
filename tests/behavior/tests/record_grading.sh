#!/usr/bin/env bash
# Offline test for lib/record.py. Never starts a real claude.
# Golden: regrade the setup cases of two committed run records from reduced results.
# Synthetic: read-order results whose tracePath points at the committed traces.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
REC="$HERE/../lib/record.py"
FX="$HERE/fixtures"
TR="$HERE/traces"
RUNS="$HERE/../../../docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs"
export PYTHONDONTWRITEBYTECODE=1

T=$(mktemp -d "${TMPDIR:-/tmp}/warden-record-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# Run an old grader from commit 7ac111f. It needs graph_first.py beside it.
OLD="$T/old"; mkdir -p "$OLD"
git -C "$HERE" show 7ac111f:tests/behavior/lib/record.py > "$OLD/record.py" 2>/dev/null
git -C "$HERE" show 7ac111f:tests/behavior/lib/graph_first.py > "$OLD/graph_first.py" 2>/dev/null

BASE=aaaaaaa1; CAND=bbbbbbb2

# run_record GRADER CONF RESULT_ARGS... -> sets OUT, ERR, RC; the record is in $T/out
run_record() {
  local grader="$1" conf="$2"; shift 2
  local args=() r
  for r in "$@"; do args+=(--result "$r"); done
  rm -rf "$T/out"
  python3 -I "$grader" --conf "$conf" --out-dir "$T/out" --runs 5 --graphify-version t \
    --fixture-hash t --id test "${args[@]}" >"$T/stdout" 2>"$T/stderr"
  RC=$?; OUT=$(cat "$T/stdout"); ERR=$(cat "$T/stderr")
}

# split_fixture FIXTURE SHA -> writes $T/<SHA>.json with that arm's result
split_fixture() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))[sys.argv[2]]
json.dump(d, open(sys.argv[3], "w"))' "$1" "$2" "$T/$2.json"
}

# synth N FILE -> read-order result with N of 5 runs graph-first (N is 3 or 4; the template holds 4)
synth() {
  python3 -I -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
runs = d["cases"][0]["arms"]["with"]
n = int(sys.argv[2])
for r in runs:
    r["tracePath"] = os.path.join(sys.argv[4], r["tracePath"])
# template: runs 0-3 graph-first, run 4 read-first; turn the last ones read-first
for i in range(n, 4):
    runs[i]["tracePath"] = os.path.join(sys.argv[4], "2_read_then_graph.jsonl")
json.dump(d, open(sys.argv[3], "w"))' "$FX/synthetic-read-order.json" "$1" "$2" "$TR"
}

# conf_line FILE CASE BASE CAND RULE N
conf_line() { printf '%s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" > "$1"; }

# row_has CASE ARM CRITERION COUNT VERDICT: the Results table in $OUT holds that row
row_has() {
  printf '%s\n' "$OUT" | grep -qF "| $1 | $2 | ${3:0:7} | $4 | $5 | $6 |"
}

# 1, 2. Golden: Results rows and run lines equal the setup lines of the committed record.
golden() {
  local id="$1" fixture="$FX/$1-setup.json" conf="$FX/$1-setup.conf" args=() sha
  for sha in $(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))))' "$fixture"); do
    split_fixture "$fixture" "$sha"
    args+=("$sha=$T/$sha.json")
  done
  run_record "$REC" "$conf" "${args[@]}"
  local rec; rec=$(ls "$T"/out/*.md 2>/dev/null | head -n1)
  if [ "$RC" -ne 0 ] || [ -z "$rec" ]; then
    fail "golden $id: record.py rc=$RC: $ERR"; return
  fi
  local got want
  got=$(grep -E '^(\| setup-|- setup-)' "$rec")
  want=$(grep -E '^(\| setup-|- setup-)' "$RUNS/2026-10-21-$id.md")
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    pass "golden $id: setup rows and run lines equal the committed record"
  else
    fail "golden $id: differs from the committed record: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -n 10)"
  fi
}
golden 726866
golden cbb2f3

# 3. Synthetic read-order: the current grader gives the verdicts of the grader at 7ac111f.
if [ ! -s "$OLD/record.py" ] || [ ! -s "$OLD/graph_first.py" ]; then
  fail "3 commit 7ac111f is not readable"
else
  synth 4 "$T/ro4.json"
  while read -r rule n want; do
    conf_line "$T/c.conf" read-order "$BASE" "$CAND" "$rule" "$n"
    run_record "$OLD/record.py" "$T/c.conf" "$BASE=$T/ro4.json" "$CAND=$T/ro4.json"
    old_rc=$RC; old_row=$(printf '%s\n' "$OUT" | grep -F "| read-order | candidate |")
    run_record "$REC" "$T/c.conf" "$BASE=$T/ro4.json" "$CAND=$T/ro4.json"
    new_row=$(printf '%s\n' "$OUT" | grep -F "| read-order | candidate |")
    if [ "$old_row" = "$new_row" ] && [ "$old_rc" -eq "$RC" ] && printf '%s' "$new_row" | grep -qF "| $want |"; then
      pass "3 read-order 4/5 $rule $n -> $want, same as 7ac111f"
    else
      fail "3 read-order $rule $n wanted $want: old='$old_row' (rc $old_rc) new='$new_row' (rc $RC)"
    fi
  done <<'ROWS'
at-least 4 PASS
at-least 5 FAIL
at-most 1 FAIL
at-most 4 PASS
ROWS
fi

# 4. both-at-least 4, baseline 4/5 and candidate 4/5: both PASS, exit 0.
synth 4 "$T/ro4.json"; synth 3 "$T/ro3.json"
conf_line "$T/b.conf" read-order "$BASE" "$CAND" both-at-least 4
run_record "$REC" "$T/b.conf" "$BASE=$T/ro4.json" "$CAND=$T/ro4.json"
if [ "$RC" -eq 0 ] && row_has read-order baseline "$BASE" 4/5 "graph-first >= 4" PASS \
   && row_has read-order candidate "$CAND" 4/5 "graph-first >= 4" PASS; then
  pass "4 both-at-least 4, 4/5 and 4/5: both rows PASS, exit 0"
else fail "4 rc=$RC: $(printf '%s\n' "$OUT" | head -n 4) $ERR"; fi

# 5. baseline 3/5: baseline row FAIL, exit 1.
run_record "$REC" "$T/b.conf" "$BASE=$T/ro3.json" "$CAND=$T/ro4.json"
if [ "$RC" -eq 1 ] && row_has read-order baseline "$BASE" 3/5 "graph-first >= 4" FAIL \
   && row_has read-order candidate "$CAND" 4/5 "graph-first >= 4" PASS; then
  pass "5 both-at-least 4, baseline 3/5: baseline row FAIL, exit 1"
else fail "5 rc=$RC: $(printf '%s\n' "$OUT" | head -n 4) $ERR"; fi

# 6. candidate 3/5: candidate row FAIL, exit 1.
run_record "$REC" "$T/b.conf" "$BASE=$T/ro4.json" "$CAND=$T/ro3.json"
if [ "$RC" -eq 1 ] && row_has read-order baseline "$BASE" 4/5 "graph-first >= 4" PASS \
   && row_has read-order candidate "$CAND" 3/5 "graph-first >= 4" FAIL; then
  pass "6 both-at-least 4, candidate 3/5: candidate row FAIL, exit 1"
else fail "6 rc=$RC: $(printf '%s\n' "$OUT" | head -n 4) $ERR"; fi

# 7. baseline "-": exit 2 and stderr names the row.
conf_line "$T/d.conf" read-order - "$CAND" both-at-least 4
run_record "$REC" "$T/d.conf" "$CAND=$T/ro4.json"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'read-order' && printf '%s' "$ERR" | grep -q 'both-at-least'; then
  pass "7 both-at-least with baseline '-': exit 2, stderr names the row"
else fail "7 rc=$RC stderr: $ERR"; fi

# 8. On a setup case, both-at-least counts triggered as at-least does.
split_fixture "$FX/726866-setup.json" c91be4c168c8dee05c37a928f8e93823e135e05c
split_fixture "$FX/726866-setup.json" 5a972be842a482c77279afc9331d0c2c77414a30
B8=c91be4c168c8dee05c37a928f8e93823e135e05c; C8=5a972be842a482c77279afc9331d0c2c77414a30
conf_line "$T/e1.conf" setup-planning "$B8" "$C8" at-least 4
run_record "$REC" "$T/e1.conf" "$B8=$T/$B8.json" "$C8=$T/$C8.json"
al=$(printf '%s\n' "$OUT" | grep -E '^\| setup-planning \| (baseline|candidate) ' | cut -d'|' -f2-5)
conf_line "$T/e2.conf" setup-planning "$B8" "$C8" both-at-least 4
run_record "$REC" "$T/e2.conf" "$B8=$T/$B8.json" "$C8=$T/$C8.json"
ba=$(printf '%s\n' "$OUT" | grep -E '^\| setup-planning \| (baseline|candidate) ' | cut -d'|' -f2-5)
if [ "$RC" -eq 1 ] && [ -n "$al" ] && [ "$al" = "$ba" ] && row_has setup-planning candidate "$C8" 4/5 "triggered >= 4" PASS \
   && row_has setup-planning baseline "$B8" 0/5 "triggered >= 4" FAIL; then
  pass "8 both-at-least on a setup case counts triggered like at-least"
else fail "8 rc=$RC at-least='$al' both='$ba': $ERR"; fi

# 9. The fixtures hold no tracePath key.
if grep -rq 'tracePath' "$FX"/726866-setup.json "$FX"/cbb2f3-setup.json; then
  fail "9 a setup fixture holds a tracePath key"
else pass "9 the setup fixtures hold no tracePath key"; fi

[ ! -d "$HERE/../lib/__pycache__" ] || fail "record.py left a __pycache__ beside the grader"
harness_exit
