#!/usr/bin/env bash
# REQ-4. Read the current CLI version and model without a model call.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

MOD="$REPO_DIR/plugins/warden/scripts/warden_pins.py"

# py CODE: run CODE with the module loaded as `wp`.
py() {
  python3 -I -c '
import sys, importlib.util, datetime, json, os
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("wp", sys.argv[1])
wp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wp)
exec(sys.argv[2])
' "$MOD" "$1"
}

PRE='
import tempfile, time
tmp = tempfile.mkdtemp(dir=os.environ["HARNESS_TMP"])
proj = os.path.join(tmp, "projects")
def line(model, ts, sidechain=False, typ="assistant"):
    return json.dumps({"type": typ, "isSidechain": sidechain, "timestamp": ts, "message": {"model": model}})
def put(rel, lines, mtime=None):
    p = os.path.join(proj, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("\n".join(lines) + "\n")
    if mtime: os.utime(p, (mtime, mtime))
UTC = datetime.timezone.utc
since = datetime.datetime(2026, 11, 20, tzinfo=UTC)
TS = "2026-11-27T10:00:00.000Z"
'
export HARNESS_TMP

chk() { # name code
  if py "$PRE
$2" ; then pass "$1"; else fail "$1"; fi
}

chk "T24 subagent folder does not count" '
put("p/s1/subagents/agent-x.jsonl", [line("claude-sonnet-5-5", TS)]*5)
assert wp.session_model(proj, since) == (None, 0), wp.session_model(proj, since)'

chk "T25 sidechain line does not count" '
put("p/s1.jsonl", [line("claude-sonnet-5-5", TS, True)]*3 + [line("claude-opus-5-5", TS)])
assert wp.session_model(proj, since) == ("claude-opus-5-5", 1)'

chk "T26 most common model and its line count" '
put("p/s1.jsonl", [line("claude-opus-5-5", TS)]*40 + [line("claude-fable-5-2", TS)]*3)
assert wp.session_model(proj, since) == ("claude-opus-5-5", 43), wp.session_model(proj, since)'

chk "T27 2-2 tie, newest line wins" '
put("p/a.jsonl", [line("claude-opus-5-5", "2026-11-26T10:00:00.000Z")]*2)
put("p/b.jsonl", [line("claude-fable-5-2", "2026-11-25T10:00:00.000Z"), line("claude-fable-5-2", "2026-11-27T12:00:00.000Z")])
assert wp.session_model(proj, since) == ("claude-fable-5-2", 4), wp.session_model(proj, since)'

chk "a line before since does not count (aware compare, +02:00 offset)" '
put("p/a.jsonl", [line("claude-opus-5-5", "2026-11-19T23:59:59.000Z"), line("claude-opus-5-5", "2026-11-20T01:00:00.000+02:00"), line("claude-opus-5-5", "2026-11-20T00:00:00.000Z")])
assert wp.session_model(proj, since) == ("claude-opus-5-5", 1), wp.session_model(proj, since)'

chk "a file with an old mtime is not read" '
put("p/old.jsonl", [line("claude-opus-5-5", TS)], mtime=time.time() - 40*86400)
assert wp.session_model(proj, since) == (None, 0)'

chk "synthetic, bad lines, non-assistant lines do not count" '
put("p/a.jsonl", [line("<synthetic>", TS), "not json", line("claude-opus-5-5", TS, typ="user"), line("", TS), "[1]", line("claude-opus-5-5", TS)])
assert wp.session_model(proj, since) == ("claude-opus-5-5", 1), wp.session_model(proj, since)'

chk "missing projects folder gives (None, 0)" '
assert wp.session_model(os.path.join(tmp, "none"), since) == (None, 0)'

chk "T28 empty window falls back to settings.json" '
sp = os.path.join(tmp, "settings.json")
open(sp, "w").write(json.dumps({"model": "claude-opus-5-5"}))
os.makedirs(proj)
r = wp.current_pins(None, proj, sp, since)
assert r["model"] == "claude-opus-5-5" and r["model_source"] == "settings" and r["model_lines"] == 0, r
assert r["cli_version"] is None and r["cli_error"] == "claude not found at schedule install", r'

chk "T29 alias or missing key gives unknown" '
sp = os.path.join(tmp, "settings.json")
open(sp, "w").write(json.dumps({"model": "opus"}))
assert wp.settings_model(sp) == "unknown"
open(sp, "w").write("{}")
assert wp.settings_model(sp) == "unknown"
assert wp.settings_model(os.path.join(tmp, "nope.json")) == "unknown"
open(sp, "w").write("garbage")
assert wp.settings_model(sp) == "unknown"
open(sp, "w").write(json.dumps({"model": "claude-opus"}))
assert wp.settings_model(sp) == "unknown"
os.makedirs(proj)
r = wp.current_pins(None, proj, sp, since)
assert r["model"] == "unknown" and r["model_source"] == "unknown", r'

chk "logs win over settings" '
sp = os.path.join(tmp, "settings.json")
open(sp, "w").write(json.dumps({"model": "claude-opus-5-5"}))
put("p/a.jsonl", [line("claude-fable-5-2", TS)]*2)
r = wp.current_pins(None, proj, sp, since)
assert (r["model"], r["model_source"], r["model_lines"]) == ("claude-fable-5-2", "logs", 2), r'

chk "cli_version with a stub that prints a version" '
s = os.path.join(tmp, "claude"); open(s, "w").write("#!/bin/sh\necho \"2.1.331 (Claude Code)\"\n"); os.chmod(s, 0o755)
assert wp.cli_version(s) == ("2.1.331", "2.1.331 (Claude Code)", None), wp.cli_version(s)'

chk "cli_version with a stub that exits 1" '
s = os.path.join(tmp, "claude"); open(s, "w").write("#!/bin/sh\necho boom\nexit 1\n"); os.chmod(s, 0o755)
v, raw, err = wp.cli_version(s)
assert v is None and err.startswith("claude --version failed:"), (v, raw, err)'

chk "cli_version with no version number, a missing file, a timeout" '
s = os.path.join(tmp, "claude"); open(s, "w").write("#!/bin/sh\necho hello\n"); os.chmod(s, 0o755)
v, raw, err = wp.cli_version(s)
assert v is None and raw == "hello" and err.startswith("claude --version failed:"), (v, raw, err)
v, raw, err = wp.cli_version(os.path.join(tmp, "missing"))
assert v is None and err.startswith("claude --version failed:"), err
open(s, "w").write("#!/bin/sh\nsleep 5\n")
v, raw, err = wp.cli_version(s, timeout=1)
assert v is None and err.startswith("claude --version failed:"), err'

chk "cli_version(None)" '
assert wp.cli_version(None) == (None, None, "claude not found at schedule install")'

chk "the module writes no file" '
put("p/a.jsonl", [line("claude-opus-5-5", TS)])
before = sorted(os.listdir(os.path.join(proj, "p")))
wp.session_model(proj, since)
assert sorted(os.listdir(os.path.join(proj, "p"))) == before'

harness_teardown
exit $((FAILURES > 0))
