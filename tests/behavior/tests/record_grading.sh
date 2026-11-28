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

# 10-12. The Model pin comes from message.model on assistant lines of the kept traces.
# model_pin RAWDIR -> prints the "- Model:" line of a record built with --raw-dir
model_pin() {
  rm -rf "$T/out"
  python3 -I "$REC" --conf "$T/b.conf" --out-dir "$T/out" --runs 5 --graphify-version t \
    --fixture-hash t --id test --raw-dir "$1" --result "$BASE=$T/ro4.json" --result "$CAND=$T/ro4.json" \
    >/dev/null 2>&1
  grep -h '^- Model:' "$T"/out/*.md 2>/dev/null
}
# stub_trace FILE MODEL -> a trace with ignored line types, a bad line, and one assistant line
stub_trace() {
  mkdir -p "$(dirname "$1")"
  {
    printf '%s\n' '{"type":"system","model":"claude-ignored-system"}'
    printf '%s\n' 'not json'
    printf '{"type":"assistant","message":{"model":"%s","content":[]}}\n' "$2"
    printf '%s\n' '{"type":"user","message":{"model":"claude-ignored-user"}}'
  } > "$1"
}

R1="$T/raw1"; stub_trace "$R1/traces/read-order/aaaaaaa/run-1.jsonl" claude-test-1
got=$(model_pin "$R1")
if [ "$got" = "- Model: claude-test-1" ]; then pass "10 one trace: the pin reads its model ID"
else fail "10 got '$got'"; fi

R2="$T/raw2"
stub_trace "$R2/traces/read-order/aaaaaaa/run-1.jsonl" claude-test-2
stub_trace "$R2/traces/read-order/bbbbbbb/run-1.jsonl" claude-test-1
got=$(model_pin "$R2")
if [ "$got" = "- Model: claude-test-1, claude-test-2" ]; then pass "11 two traces: both IDs listed, sorted"
else fail "11 got '$got'"; fi

R3="$T/raw3"; mkdir -p "$R3/traces/read-order/aaaaaaa"
printf '%s\n' '{"type":"system"}' > "$R3/traces/read-order/aaaaaaa/run-1.jsonl"
got=$(model_pin "$R3")
got_empty=$(model_pin "")
if [ "$got" = "- Model: unknown (no model ID in traces)" ] && [ "$got_empty" = "$got" ]; then
  pass "12 no ID (or no raw dir): the pin reads unknown"
else fail "12 got '$got' / '$got_empty'"; fi

# 13. both-at-least 4: a baseline with 4 graph-first hits and 1 errored run FAILs, candidate 5/5 PASSes, exit 1.
synth 4 "$T/ro4.json"
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = d["cases"][0]["arms"]["with"]
r[4]["error"] = "stub failure"
json.dump(d, open(sys.argv[2], "w"))' "$T/ro4.json" "$T/ro4e.json"
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = d["cases"][0]["arms"]["with"]
r[4]["tracePath"] = r[0]["tracePath"]
json.dump(d, open(sys.argv[2], "w"))' "$T/ro4.json" "$T/ro5.json"
conf_line "$T/f.conf" read-order "$BASE" "$CAND" both-at-least 4
run_record "$REC" "$T/f.conf" "$BASE=$T/ro4e.json" "$CAND=$T/ro5.json"
if [ "$RC" -eq 1 ] && row_has read-order baseline "$BASE" "4/5 (1 errored)" "graph-first >= 4" FAIL \
   && row_has read-order candidate "$CAND" 5/5 "graph-first >= 4" PASS; then
  pass "13 both-at-least 4, baseline 4 hits + 1 errored: baseline row FAIL, exit 1"
else fail "13 rc=$RC: $(printf '%s\n' "$OUT" | head -n 5) $ERR"; fi

# 14. a five-column conf keeps today's Results header
conf_line "$T/h.conf" read-order "$BASE" "$CAND" at-least 4
run_record "$REC" "$T/h.conf" "$BASE=$T/ro4.json" "$CAND=$T/ro4.json"
if printf '%s\n' "$OUT" | grep -qxF '| case | arm | SHA | count/runs | criterion | result |'; then
  pass "14 five-column conf: Results header has no model column"
else fail "14 header: $(printf '%s\n' "$OUT" | grep '^| case' | head -n2) $ERR"; fi

# Summary tests. sum_record CONF OUTDIR [EXTRA...] -> RC, OUT, ERR; results are the ro4 template with a stub version line.
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeVersion"] = "2.1.305 (Claude Code)"
json.dump(d, open(sys.argv[2], "w"))' "$T/ro4.json" "$T/ro4v.json"
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["cases"][0]["arms"]["with"][4]["error"] = "stub failure"
json.dump(d, open(sys.argv[2], "w"))' "$T/ro4v.json" "$T/ro4ve.json"
SRAW="$T/sraw"; rm -rf "$SRAW"
mkdir -p "$SRAW/traces/read-order/bbbbbbb" "$SRAW/traces/read-order/bbbbbbb-claude-x-1"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-main-1","content":[]}}' > "$SRAW/traces/read-order/bbbbbbb/run-1.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-x-1","content":[]}}' > "$SRAW/traces/read-order/bbbbbbb-claude-x-1/run-1.jsonl"
printf 'read-order - %s at-least 4\nread-order - %s at-least 4 claude-x-1\n' "$CAND" "$CAND" > "$T/s.conf"
sum_record() {
  local conf="$1" outdir="$2"; shift 2
  rm -rf "$outdir"
  python3 -I "$REC" --conf "$conf" --out-dir "$outdir" --runs 5 --graphify-version "graphify 0.9.92" \
    --fixture-hash fh --id test --raw-dir "$SRAW" "$@" >"$T/stdout" 2>"$T/stderr"
  RC=$?; OUT=$(cat "$T/stdout"); ERR=$(cat "$T/stderr")
}

# 41. --summary writes every field of the summary, with the arms of the arms file.
sum_record "$T/s.conf" "$T/sout" --summary --result "$CAND=$T/ro4v.json" --result "$CAND@claude-x-1=$T/ro4v.json"
sj=$(ls "$T"/sout/*.json 2>/dev/null | head -n1)
if [ "$RC" -eq 0 ] && [ -n "$sj" ] && python3 -I - "$sj" "$CAND" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
ok = (d["schema"] == 1 and d["id"] == "test" and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["date"])
      and d["sha"] == sys.argv[2] and d["cli_version"] == "2.1.305" and d["cli_version_raw"] == "2.1.305 (Claude Code)"
      and d["model"] == "claude-main-1" and d["graphify_version"] == "graphify 0.9.92" and d["fixture_hash"] == "fh"
      and d["runs"] == 5 and len(d["cases"]) == 2)
a, b = d["cases"]
ok = ok and (a["case"], a["arm"], a["model"], a["count"], a["errored"], a["runs"], a["rule"], a["threshold"], a["result"]) == \
    ("read-order", "main", "claude-main-1", 4, 0, 5, "at-least", 4, "PASS")
ok = ok and (b["arm"], b["model"], b["result"]) == ("ab", "claude-x-1", "PASS")
sys.exit(0 if ok else 1)
PY
then pass "41 --summary writes every field, cli_version 2.1.305"; else fail "41 rc=$RC json=$sj: $(cat "$sj" 2>/dev/null) $ERR"; fi
case "$sj" in */????-??-??-test.json) ;; *) fail "41 summary name: $sj" ;; esac
[ -f "$(ls "$T"/sout/*.md | head -n1)" ] && [ "$(basename "${sj%.json}")" = "$(basename "$(ls "$T"/sout/*.md | head -n1)" .md)" ] && pass "41 summary sits beside the Markdown record" || fail "41 name differs from the record"

# 41b. the summary has the key set and the JSON types of the golden fixture.
if python3 -I - "$sj" "$FX/suite-summary-golden.json" <<'PY'
import json, sys
got, want = (json.load(open(p)) for p in sys.argv[1:3])
def types(d): return {k: type(v).__name__ for k, v in d.items() if k != "cases"}
bad = []
if types(got) != types(want): bad.append("top-level: %r vs %r" % (types(got), types(want)))
if not got["cases"] or not all(isinstance(c, dict) for c in got["cases"]): bad.append("cases")
else:
    for c in got["cases"]:
        for w in want["cases"]:
            if {k: type(v).__name__ for k, v in c.items()} != {k: type(v).__name__ for k, v in w.items()}:
                bad.append("case entry %r" % c)
                break
if bad: print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
then pass "41b summary keys and types equal the golden fixture"; else fail "41b summary differs from the golden fixture"; fi

# 42. an errored run: ERRORED in the summary, FAIL in the Markdown row.
printf 'read-order - %s at-least 4\n' "$CAND" > "$T/s1.conf"
sum_record "$T/s1.conf" "$T/sout2" --summary --result "$CAND=$T/ro4ve.json"
sj2=$(ls "$T"/sout2/*.json 2>/dev/null | head -n1)
if [ "$RC" -eq 1 ] && [ -n "$sj2" ] && python3 -I -c '
import json, sys
c = json.load(open(sys.argv[1]))["cases"][0]
sys.exit(0 if (c["result"], c["errored"]) == ("ERRORED", 1) else 1)' "$sj2" \
   && row_has read-order candidate "$CAND" "4/5 (1 errored)" "graph-first >= 4" FAIL; then
  pass "42 errored run: ERRORED in the summary, FAIL in the Markdown row"
else fail "42 rc=$RC json=$sj2: $(cat "$sj2" 2>/dev/null) $OUT"; fi

# 43. no --summary, no .json.
sum_record "$T/s1.conf" "$T/sout3" --result "$CAND=$T/ro4v.json"
if [ "$RC" -eq 0 ] && [ -z "$(ls "$T"/sout3/*.json 2>/dev/null)" ] && [ -n "$(ls "$T"/sout3/*.md 2>/dev/null)" ]; then
  pass "43 without --summary, no .json"
else fail "43 rc=$RC: $(ls "$T/sout3" 2>&1)"; fi

# 43. a two-arm run (a baseline other than "-") writes no summary, but the Markdown record stays.
conf_line "$T/s2.conf" read-order "$BASE" "$CAND" at-least 4
sum_record "$T/s2.conf" "$T/sout5" --summary --result "$BASE=$T/ro4v.json" --result "$CAND=$T/ro4v.json"
if [ "$RC" -eq 0 ] && [ -z "$(ls "$T"/sout5/*.json 2>/dev/null)" ] && [ -n "$(ls "$T"/sout5/*.md 2>/dev/null)" ] \
   && printf '%s' "$ERR" | grep -qF 'summary: skipped, two-arm run'; then
  pass "43 two-arm run with --summary: no .json, Markdown written, notice on stderr"
else fail "43 rc=$RC: $(ls "$T/sout5" 2>&1) $ERR"; fi

# T55 (D3, REQ-6.8). a merge-check stub run writes no summary.
sum_record "$T/s1.conf" "$T/sout7" --summary --merge-check-stub --result "$CAND=$T/ro4v.json"
if [ -z "$(ls "$T"/sout7/*.json 2>/dev/null)" ] && [ -n "$(ls "$T"/sout7/*.md 2>/dev/null)" ] && printf '%s' "$ERR" | grep -qF 'summary: skipped, merge check stub'; then
  pass "T55 merge-check stub run: no .json, notice on stderr"
else fail "T55 rc=$RC: $(ls "$T/sout7" 2>&1) $ERR"; fi

# 44. a partial result (exit 2) writes no .json.
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1])); d["partial"] = True
json.dump(d, open(sys.argv[2], "w"))' "$T/ro4v.json" "$T/ro4p.json"
sum_record "$T/s1.conf" "$T/sout4" --summary --result "$CAND=$T/ro4p.json"
if [ "$RC" -eq 2 ] && [ -z "$(ls "$T"/sout4/*.json 2>/dev/null)" ]; then
  pass "44 partial result: exit 2, no .json"
else fail "44 rc=$RC: $(ls "$T/sout4" 2>&1)"; fi

# 45. <synthetic> never reaches the summary models; each model is one ID (the most common one).
SRAW2="$T/sraw2"; rm -rf "$SRAW2"; mkdir -p "$SRAW2/traces/read-order/bbbbbbb"
{ printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[]}}'; } > "$SRAW2/traces/read-order/bbbbbbb/run-1.jsonl"
SRAW_SAVE="$SRAW"; SRAW="$SRAW2"
sum_record "$T/s1.conf" "$T/sout6" --summary --result "$CAND=$T/ro4v.json"
SRAW="$SRAW_SAVE"
sj6=$(ls "$T"/sout6/*.json 2>/dev/null | head -n1)
if [ "$RC" -eq 0 ] && [ -n "$sj6" ] && python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["model"] == "claude-opus-5-5" and d["cases"][0]["model"] == "claude-opus-5-5" else 1)' "$sj6"; then
  pass "45 summary models drop <synthetic> and name one model ID"
else fail "45 rc=$RC: $(cat "$sj6" 2>/dev/null) $ERR"; fi

# 46. a baseline and a candidate on one commit with different models: the Results table has the model column.
printf 'read-order %s %s at-least 4 claude-x-1\n' "$CAND" "$CAND" > "$T/s3.conf"
run_record "$REC" "$T/s3.conf" "$CAND=$T/ro4.json" "$CAND@claude-x-1=$T/ro4.json"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF '| case | arm | SHA | model | count/runs | criterion | result |'; then
  pass "46 baseline and candidate on one commit, two models: model column"
else fail "46 rc=$RC: $(printf '%s\n' "$OUT" | grep '^| case' | head -n2) $ERR"; fi

[ ! -d "$HERE/../lib/__pycache__" ] || fail "record.py left a __pycache__ beside the grader"
harness_exit
