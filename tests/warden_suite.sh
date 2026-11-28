#!/usr/bin/env bash
# REQ-3, REQ-5. The suite summary reader, the combined view and coverage.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

SCRIPTS="$REPO_DIR/plugins/warden/scripts"
GOLDEN="$TESTS_DIR/behavior/tests/fixtures/suite-summary-golden.json"

# py CODE: run CODE with warden_suite imported as `ws`. $T is a fresh temp folder.
py() {
  python3 -I -c '
import sys, json, os
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import warden_suite as ws
T = sys.argv[3]
def summ(name, id, date, cases, cli="2.1.331", model="claude-opus-5-5"):
    d = {"schema": 1, "id": id, "date": date, "sha": "a" * 40, "cli_version": cli,
         "model": model, "cases": cases}
    with open(os.path.join(T, name), "w") as f:
        json.dump(d, f)
def c(case, result, arm="main", count=5, errored=0):
    return {"case": case, "arm": arm, "model": "m", "count": count, "errored": errored,
            "runs": 5, "rule": "at-least", "threshold": 4, "result": result}
exec(sys.argv[2])
' "$SCRIPTS" "$1" "$(mktemp -d "$HARNESS_TMP/t.XXXXXX")"
}
check() { # check NAME CODE
  if py "$2" 2>"$HARNESS_TMP/err"; then pass "$1"; else fail "$1: $(tail -3 "$HARNESS_TMP/err")"; fi
}

check "golden fixture is readable; deleting any required key makes it unreadable" '
import shutil
shutil.copy(sys.argv[0] if False else "'"$GOLDEN"'", os.path.join(T, "2026-11-27-69257e.json"))
ok, bad = ws.load_summaries(T)
assert len(ok) == 1 and bad == [], (ok, bad)
os.remove(os.path.join(T, "2026-11-27-69257e.json"))
good = json.load(open("'"$GOLDEN"'"))
for k in ("schema", "id", "date", "sha", "cli_version", "model", "cases"):
    d = dict(good); del d[k]
    p = os.path.join(T, "x.json"); json.dump(d, open(p, "w"))
    ok, bad = ws.load_summaries(T)
    assert ok == [] and bad == [p], (k, ok, bad)
'

check "parse_cli_version and minor" '
assert ws.parse_cli_version("2.1.331 (Claude Code)") == "2.1.331"
assert ws.parse_cli_version("garbage") is None
assert ws.minor("2.1.331") == "2.1"
assert ws.minor(None) is None
'

check "read_suite_cases skips comments and blanks, keeps order" '
p = os.path.join(T, "suite.conf")
open(p, "w").write("# head\n\nb at-least 4\n  # indented\na exact 5\n\nc at-least 3\n")
assert ws.read_suite_cases(p) == ["b", "a", "c"], ws.read_suite_cases(p)
'

check "load_summaries orders oldest first and lists unreadable files" '
summ("2026-11-02-b.json", "b", "2026-11-02T10:00:00Z", [c("x", "PASS")])
summ("2026-11-01-a.json", "a", "2026-11-01T10:00:00Z", [c("x", "PASS")])
open(os.path.join(T, "bad.json"), "w").write("{nope")
d = {"schema": 1, "id": "n", "date": "2026-11-03T00:00:00Z", "sha": "s", "cli_version": "1", "model": "m"}
json.dump(d, open(os.path.join(T, "nocases.json"), "w"))
ok, bad = ws.load_summaries(T)
assert [s["id"] for s in ok] == ["a", "b"], ok
assert sorted(os.path.basename(b) for b in bad) == ["bad.json", "nocases.json"], bad
'

check "combined_view: a newer passing rerun replaces an errored case" '
summ("1.json", "full", "2026-11-01T10:00:00Z", [c("read-order", "ERRORED", errored=1), c("other", "PASS")])
summ("2.json", "rerun", "2026-11-02T10:00:00Z", [c("read-order", "PASS")])
v = ws.combined_view(ws.load_summaries(T)[0])
assert v["read-order"]["result"] == "PASS" and v["read-order"]["id"] == "rerun", v
assert v["other"]["id"] == "full"
assert set(v["read-order"]) == {"result", "count", "runs", "errored", "id"}
'

check "combined_view ignores ab entries" '
summ("1.json", "a", "2026-11-01T10:00:00Z", [c("x", "FAIL", arm="ab"), c("y", "PASS")])
v = ws.combined_view(ws.load_summaries(T)[0])
assert "x" not in v and "y" in v, v
'

check "combined_view keeps ERRORED when every entry is ERRORED" '
summ("1.json", "a", "2026-11-01T10:00:00Z", [c("x", "ERRORED", errored=1)])
summ("2.json", "b", "2026-11-02T10:00:00Z", [c("x", "ERRORED", errored=2)])
v = ws.combined_view(ws.load_summaries(T)[0])
assert v["x"]["result"] == "ERRORED" and v["x"]["id"] == "b", v
'

CASES5='["a", "b", "c", "d", "e"]'
check "is_covered is false for a single-case summary against five suite cases" '
summ("1.json", "a", "2026-11-01T10:00:00Z", [c("a", "PASS")])
S = ws.load_summaries(T)[0]
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", "2.1") is False
'

check "is_covered is true for a full run plus a rerun of its errored case" '
summ("1.json", "full", "2026-11-01T10:00:00Z", [c(x, "ERRORED" if x == "e" else "PASS", errored=1 if x == "e" else 0) for x in "abcde"])
S = ws.load_summaries(T)[0]
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", "2.1") is False
summ("2.json", "rerun", "2026-11-02T10:00:00Z", [c("e", "PASS")])
S = ws.load_summaries(T)[0]
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", "2.1") is True
'

check "is_covered ignores a patch difference" '
summ("1.json", "a", "2026-11-01T10:00:00Z", [c(x, "PASS") for x in "abcde"], cli="2.1.331")
S = ws.load_summaries(T)[0]
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", ws.minor("2.1.340")) is True
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", "2.2") is False
assert ws.is_covered(S, '"$CASES5"', "claude-sonnet-5-5", "2.1") is False
'

check "newest_covered skips a newer group with an ERRORED case" '
summ("1.json", "old", "2026-11-01T10:00:00Z", [c(x, "PASS") for x in "abcde"], cli="2.1.331")
summ("2.json", "new", "2026-11-02T10:00:00Z", [c(x, "ERRORED", errored=1) if x == "a" else c(x, "PASS") for x in "abcde"], cli="2.2.5")
S = ws.load_summaries(T)[0]
key, grp = ws.newest_covered(S, '"$CASES5"')
assert key == ("2.1", "claude-opus-5-5") and [s["id"] for s in grp] == ["old"], (key, grp)
assert ws.newest_covered(S[1:], '"$CASES5"') is None
'

check "is_covered with cli_minor None counts any covered group of that model" '
summ("1.json", "a", "2026-11-01T10:00:00Z", [c(x, "PASS") for x in "abcde"], cli="2.1.331")
S = ws.load_summaries(T)[0]
assert ws.is_covered(S, '"$CASES5"', "claude-opus-5-5", None) is True
assert ws.is_covered(S, '"$CASES5"', "claude-sonnet-5-5", None) is False
'

harness_exit
