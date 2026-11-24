#!/usr/bin/env bash
# REQ-1 to REQ-9. The warden-lesson nudge subcommand: triggers, delivery, records, state and safety.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

PLUGIN="$REPO_DIR/plugins/warden"
SCRIPT="${WARDEN_LESSON_SCRIPT:-$PLUGIN/scripts/warden-lesson}"
SETUP="$PLUGIN/scripts/graphify-setup"
STUBS="$TESTS_DIR/behavior/stubs"
GITDIR_BIN=$(dirname "$(command -v git)")
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$GITDIR_BIN"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_NOSYSTEM=1
N=0

# new_session: fresh HOME, inbox, transcript file and session id. The transcript is older than any repository made after it.
new_session() {
  N=$((N + 1))
  W=$(cd -P "$(mktemp -d "$HARNESS_TMP/case.XXXXXX")" && pwd)
  export HOME="$W/home"
  mkdir -p "$HOME/.claude"
  export WARDEN_LESSON_ROOT="$W/inbox"
  unset WARDEN_LESSON_OFF
  export WARDEN_STUB_EXPECT_GRAPHIFY="$STUBS/graphify"
  export PATH="$STUBS:$SAFE_PATH"
  export SID="sess$N"
  export TRANSCRIPT="$W/transcript.jsonl"
  NUDGE_SCRIPT="$SCRIPT"
  : > "$TRANSCRIPT"
  sleep 0.05
  ND="$HOME/.claude/warden/nudge"
  LOG="$WARDEN_LESSON_ROOT/sessions/$SID.jsonl"
}

# pl TOOL CWD ARG [agent]: print a hook payload. ARG is a command (Bash), a skill name (Skill, "-" for none).
pl() {
  python3 -I -c '
import json, sys, os
tool, cwd, arg = sys.argv[1:4]
agent = sys.argv[4] if len(sys.argv) > 4 else ""
ti = {}
if tool == "Bash":
    ti = {"command": arg}
elif tool == "Skill" and arg != "-":
    ti = {"skill": arg}
p = {"session_id": os.environ["SID"], "transcript_path": os.environ["TRANSCRIPT"], "cwd": cwd,
     "tool_name": tool, "tool_input": ti, "hook_event_name": "PostToolUse", "tool_use_id": "tu1"}
if agent == "agent":
    p["agent_id"] = "a1"
    p["agent_type"] = "general-purpose"
print(json.dumps(p))' "$@"
}

# run TOOL CWD ARG [agent]: pipe a payload to the subcommand. Sets OUT and RC.
run() {
  OUT=$(pl "$@" | python3 -I "$NUDGE_SCRIPT" nudge 2>/dev/null)
  RC=$?
}

# ctx: the additionalContext of OUT, or nothing.
ctx() {
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
t = sys.stdin.read()
if t.strip():
    d = json.loads(t)
    assert list(d) == ["hookSpecificOutput"] and d["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
    print(d["hookSpecificOutput"]["additionalContext"])'
}

expect_empty() {
  if [ -z "$OUT" ] && [ "$RC" = 0 ]; then pass "$1"; else fail "$1 (rc $RC, output: $OUT)"; fi
}

# expect_nudge LABEL VARIANT: one nudge of that variant.
expect_nudge() {
  local c
  c=$(ctx 2>/dev/null)
  if [ "$RC" != 0 ] || [ -z "$c" ]; then fail "$1 (rc $RC, output: $OUT)"; return; fi
  local skill=0 commit=0
  case "$c" in *"before the first code exploration in this skill"*) skill=1 ;; esac
  case "$c" in *"before your next code exploration in that repository"*) commit=1 ;; esac
  if [ "$2" = skill ] && [ $skill = 1 ] && [ $commit = 0 ]; then pass "$1"
  elif [ "$2" = commit ] && [ $commit = 1 ] && [ $skill = 0 ]; then pass "$1"
  else fail "$1 (wrong variant: $c)"; fi
}

mkrepo() { git init -q "$1" 2>/dev/null; }
# add_files DIR N: commit N source files.
add_files() {
  local i
  for i in $(seq 1 "$2"); do echo "x = $i" > "$1/f$i.py"; done
  git -C "$1" add -A && git -C "$1" commit -q -m files
}
state_len() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$ND/$SID.json" "$1" 2>/dev/null || echo missing; }
log_count() { [ -f "$LOG" ] && grep -c "\"t\":\"$1\"" "$LOG" || echo 0; }

# T17. Bad input exits 0 with no output.
new_session
for bad in 'not json' '[1, 2]' '{"tool_name": "Bash"}' '{"session_id": "", "tool_name": "Bash"}'; do
  OUT=$(printf '%s' "$bad" | python3 -I "$SCRIPT" nudge 2>/dev/null); RC=$?
  expect_empty "T17 bad input '$bad' exits 0 silently"
done

# T1. git init marks pending. The Skill trigger waits for 20 source files, fires once.
new_session
R="$W/repo"; mkrepo "$R"
run Bash "$R" "git init"
expect_empty "T1 git init prints nothing"
[ "$(state_len pending)" = 1 ] && pass "T1 the repository is pending" || fail "T1 pending count is $(state_len pending)"
run Skill "$R" "superpowers:writing-plans"
expect_empty "T1 namespaced Skill payload prints nothing while small"
add_files "$R" 20
run Skill "$R" "writing-plans"
expect_nudge "T1 bare Skill name nudges once after 20 source files" skill
run Skill "$R" "writing-plans"
expect_empty "T1 a third Skill payload prints nothing"
[ "$(state_len nudged)" = 1 ] && pass "T1 state lists the repository as nudged" || fail "T1 nudged count is $(state_len nudged)"

# T1 (more). A skill outside the list and a Skill payload without a name.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
run Skill "$R" "superpowers:executing-plans"
expect_empty "T1 superpowers:executing-plans does not trigger"
run Skill "$R" "-"
expect_nudge "T1 a Skill payload with no skill name triggers (REQ-2.6)" skill

# T2. The repository is created below cwd, in a chained command.
new_session
P="$W/parent"; mkdir "$P"; mkrepo "$P/app"
run Bash "$P" "npx create-next-app app && cd app && git init"
[ "$(state_len pending)" = 1 ] && pass "T2 app is pending" || fail "T2 pending count is $(state_len pending)"
add_files "$P/app" 20
run Skill "$P" "superpowers:brainstorming"
expect_nudge "T2 a Skill payload from the parent nudges app" skill
case "$(ctx)" in *"cd $P/app && "*) pass "T2 the nudge names app" ;; *) fail "T2 nudge does not name app: $(ctx)" ;; esac

# T3. A repository made before the transcript is never marked.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
sleep 0.05; rm -f "$TRANSCRIPT"; : > "$TRANSCRIPT"
run Bash "$R" "git init"
run Bash "$R" "git commit -m x"
expect_empty "T3 commit in an older repository prints nothing"
run Skill "$R" "writing-plans"
expect_empty "T3 Skill payload in an older repository prints nothing"
[ "$(state_len pending)" = 0 ] && pass "T3 nothing is pending" || fail "T3 pending count is $(state_len pending)"

# T4. The commit trigger.
new_session
R="$W/repo"; mkrepo "$R"
run Bash "$R" "git init"
run Bash "$R" "git commit -m x"
expect_empty "T4 commit while small prints nothing"
add_files "$R" 20
run Bash "$R" "git commit -m more"
expect_nudge "T4 commit after 20 source files nudges" commit

# T5. A subagent commit queues a marker. The next main-session call delivers it.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
run Bash "$R" "git commit -m x" agent
expect_empty "T5 subagent commit prints nothing"
assert_file "$ND/$SID.ready"
run Bash "$R" "ls"
expect_nudge "T5 the next main-session call delivers the commit variant" commit
assert_absent "$ND/$SID.ready"
run Bash "$R" "ls"
expect_empty "T5 a second call prints nothing"

# T6. A subagent Skill call never triggers.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
run Skill "$R" "writing-plans" agent
expect_empty "T6 subagent Skill payload prints nothing"
assert_absent "$ND/$SID.ready"

# T7. A declined or ready repository is dropped.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
(cd "$R" && "$SETUP" decline >/dev/null)
run Skill "$R" "writing-plans"
expect_empty "T7 declined: Skill payload prints nothing"
run Bash "$R" "git commit -m x"
expect_empty "T7 declined: commit prints nothing"
[ "$(state_len dropped)" = 1 ] && pass "T7 declined repository is dropped" || fail "T7 dropped count is $(state_len dropped)"
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
mkdir "$R/graphify-out"; echo '{}' > "$R/graphify-out/graph.json"; git -C "$R" config warden.graphify manual
run Skill "$R" "writing-plans"
expect_empty "T7 ready: Skill payload prints nothing"
run Bash "$R" "git commit -m x"
expect_empty "T7 ready: commit prints nothing"
[ "$(state_len dropped)" = 1 ] && pass "T7 ready repository is dropped" || fail "T7 dropped count is $(state_len dropped)"

# T8. No graphify on PATH gives no-cli, and the commit nudges.
new_session
if PATH="$SAFE_PATH" command -v graphify >/dev/null 2>&1; then
  pass "T8 skipped: a graphify sits in the system path"
else
  export PATH="$SAFE_PATH"
  R="$W/repo"; mkrepo "$R"; add_files "$R" 20
  run Bash "$R" "git init"
  run Bash "$R" "git commit -m x"
  expect_nudge "T8 no-cli: commit nudges" commit
fi

# T9. A session newer than the repository: nothing happens.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
sleep 0.05; rm -f "$TRANSCRIPT"; : > "$TRANSCRIPT"
run Bash "$R" "ls"; expect_empty "T9 ls prints nothing"
run Bash "$R" "git commit -m x"; expect_empty "T9 commit prints nothing"
run Skill "$R" "writing-plans"; expect_empty "T9 Skill payload prints nothing"
assert_absent "$ND/$SID.ready"

# T10. setup-call records.
new_session
P="$W/parent"; mkdir "$P"; R="$P/r"; mkrepo "$R"
ID=$(python3 -I -c 'import os,sys,hashlib,subprocess
top=os.path.realpath(sys.argv[1])
c=os.path.realpath(subprocess.check_output(["git","-C",top,"rev-parse","--path-format=absolute","--git-common-dir"],text=True).strip())
print(os.path.basename(top)+"#"+hashlib.sha256(c.encode()).hexdigest()[:8])' "$R")
run Bash "$P" "cd \"$R\" && \"$SETUP\" status"
[ "$(log_count setup-call)" = 1 ] && pass "T10 one setup-call line" || fail "T10 setup-call count is $(log_count setup-call)"
run Bash "$P" "cd \"$R\" && \"$SETUP\" status" agent
[ "$(log_count setup-call)" = 2 ] && pass "T10 a subagent call writes one more" || fail "T10 setup-call count is $(log_count setup-call)"
run Bash "$R" "\"$SETUP\" status"
[ "$(log_count setup-call)" = 3 ] && pass "T10 a command without cd uses cwd" || fail "T10 setup-call count is $(log_count setup-call)"
if python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if "setup-call" in l]
assert len(rows)==3 and all(r["repo"]==sys.argv[2] and set(r)=={"t","ts","repo"} for r in rows)
t=open(sys.argv[1]).read()
assert sys.argv[3] not in t and "status" not in t' "$LOG" "$ID" "$R"; then pass "T10 lines hold the repository ID only"; else fail "T10 setup-call lines are wrong"; fi

# T11. The nudge record.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"; run Bash "$R" "git commit -m x"
if python3 -I -c 'import json,re,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if "\"nudge\"" in l]
assert len(rows)==1
r=rows[0]
assert set(r)=={"t","ts","repo","trigger","via","word"}, r
assert re.match(r"^[^#/]+#[0-9a-f]{8}$", r["repo"])
assert r["trigger"] in ("skill","commit") and r["via"] in ("direct","marker")
assert sys.argv[2] not in open(sys.argv[1]).read()' "$LOG" "$R"; then pass "T11 one nudge line with the right fields and no path"; else fail "T11 nudge record is wrong: $(cat "$LOG" 2>/dev/null)"; fi

# T12. Rendering.
new_session
R="$W/my \"odd\" repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"; run Skill "$R" "writing-plans"
if ctx | python3 -I -c 'import sys,shlex,os
line=[l for l in sys.stdin.read().splitlines() if l.startswith("cd ")][0]
w=shlex.split(line)
assert w==["cd",os.path.realpath(sys.argv[1]),"&&",sys.argv[2],"status"], w' "$R" "$SETUP"; then pass "T12A command line splits into cd, repo, &&, setup, status"; else fail "T12A command line is wrong: $(ctx)"; fi
copy_plugin() { rm -rf "$W/plug"; cp -R "$PLUGIN" "$W/plug"; NUDGE_SCRIPT="$W/plug/scripts/warden-lesson"; }
break_template() { # LABEL PYTHON-EXPR on text t
  new_session; copy_plugin
  python3 -I -c 'import sys; f=sys.argv[1]; t=open(f).read(); t=eval(sys.argv[2]); open(f,"w").write(t)' "$W/plug/hooks/setup-nudge.md" "$2"
  R="$W/repo"; mkrepo "$R"; add_files "$R" 20
  run Bash "$R" "git init"; run Skill "$R" "writing-plans"
  expect_empty "$1 prints nothing"
  [ "$(state_len pending)" = 1 ] && pass "$1 keeps the repository pending" || fail "$1 pending count is $(state_len pending)"
}
break_template "T12B no {{REPO}}" 't.replace("{{REPO}}", "x")'
break_template "T12C {{REPO}} twice" 't + "{{REPO}}"'
break_template "T12D no {{GRAPHIFY_SETUP}}" 't.replace("{{GRAPHIFY_SETUP}}", "x")'
break_template "T12D {{GRAPHIFY_SETUP}} twice" 't + "{{GRAPHIFY_SETUP}}"'

# T14. A slow status script ends within 5 seconds.
new_session; copy_plugin
printf '#!/usr/bin/env bash\nsleep 10\necho ask\n' > "$W/plug/scripts/graphify-setup"; chmod +x "$W/plug/scripts/graphify-setup"
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
T0=$(python3 -I -c 'import time; print(time.time())')
run Skill "$R" "writing-plans"
T1=$(python3 -I -c 'import time; print(time.time())')
expect_empty "T14 a slow status script gives no output"
python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 5 else 1)' "$T0" "$T1" && pass "T14 the run ends within 5 seconds" || fail "T14 the run took too long"
[ "$(state_len pending)" = 1 ] && pass "T14 the repository stays pending" || fail "T14 pending count is $(state_len pending)"

# T15. Two runs against one marker deliver once.
new_session
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"
run Bash "$R" "git commit -m x" agent
pl Bash "$R" "ls" | python3 -I "$SCRIPT" nudge > "$W/o1" 2>/dev/null &
pl Bash "$R" "ls" | python3 -I "$SCRIPT" nudge > "$W/o2" 2>/dev/null &
wait
if [ "$(cat "$W/o1" "$W/o2" | grep -c hookSpecificOutput)" = 1 ]; then pass "T15 exactly one run delivered"; else fail "T15 delivery count wrong: $(cat "$W/o1" "$W/o2")"; fi

# T16. Cleanup of old state.
new_session
mkdir -p "$ND"
for f in old.json old.ready old.claimed.1 keep.json keep.claimed.2; do : > "$ND/$f"; done
python3 -I -c 'import os,sys,time
t=time.time()-8*86400
for f in sys.argv[2:]: os.utime(os.path.join(sys.argv[1],f),(t,t))' "$ND" old.json old.ready old.claimed.1
R="$W/repo"; mkrepo "$R"
run Bash "$R" "git init"
if [ ! -e "$ND/old.json" ] && [ ! -e "$ND/old.ready" ] && [ ! -e "$ND/old.claimed.1" ] && [ -e "$ND/keep.json" ] && [ -e "$ND/keep.claimed.2" ]; then pass "T16 old files are removed and current files stay"; else fail "T16 cleanup wrong: $(ls "$ND")"; fi

# T18. With lesson capture off the nudge still works and writes no log.
new_session
export WARDEN_LESSON_OFF=1
R="$W/repo"; mkrepo "$R"; add_files "$R" 20
run Bash "$R" "git init"; run Bash "$R" "git commit -m x"
expect_nudge "T18 commit still nudges with WARDEN_LESSON_OFF=1" commit
assert_absent "$LOG"
unset WARDEN_LESSON_OFF

harness_exit
