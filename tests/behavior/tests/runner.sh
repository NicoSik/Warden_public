#!/usr/bin/env bash
# Offline tests for run-behavior and lib/record.py. Never starts a real claude:
# PATH holds only stubs, and each stub exits 99 unless called by its expected path.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
RUN="$HERE/../run-behavior"
STUBS="$HERE/../stubs"

T=$(mktemp -d "${TMPDIR:-/tmp}/warden-runner-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/bin-nographify" "$T/bin-noclaude" "$T/runs"
ln -s "$STUBS/claude" "$T/bin/claude"
ln -s "$STUBS/graphify" "$T/bin/graphify"
ln -s "$STUBS/claude" "$T/bin-nographify/claude"
ln -s "$STUBS/graphify" "$T/bin-noclaude/graphify"

export HOME="$T/home" TMPDIR="$T/tmp" STUB_TMP="$T/tmp"
export WARDEN_STUB_LOG="$T/stub.log"
export WARDEN_STUB_EXPECT_CLAUDE="$T/bin/claude"
export WARDEN_STUB_EXPECT_GRAPHIFY="$T/bin/graphify"
export WARDEN_BEHAVIOR_RECORD_DIR="$T/runs"
export WARDEN_BEHAVIOR_RAW_DIR="$HOME/raw"; mkdir -p "$WARDEN_BEHAVIOR_RAW_DIR"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
GOODPATH="$T/bin:$SYSPATH"

[ "$(PATH=$GOODPATH command -v claude)" = "$T/bin/claude" ] || { echo "stub not first on PATH"; exit 1; }

reset() { : > "$WARDEN_STUB_LOG"; rm -f "$WARDEN_STUB_LOG.count"; rm -rf "$T/runs" "$WARDEN_BEHAVIOR_RAW_DIR"; mkdir -p "$T/runs" "$WARDEN_BEHAVIOR_RAW_DIR"; }
evals() { grep -c '^CALL eval' "$WARDEN_STUB_LOG"; }

cd "$HERE/../../.." || exit 1
rm -rf tests/behavior/lib/__pycache__
STATUS_BEFORE=$(git status --porcelain)
REFS_BEFORE=$(git for-each-ref)

# 1. no graphify -> exit 3, no eval
reset
out=$(PATH="$T/bin-nographify:$SYSPATH" WARDEN_STUB_EXPECT_CLAUDE="$T/bin-nographify/claude" bash "$RUN" --yes 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -q "graphify --version" && pass "1 missing graphify: exit 3, no eval" || fail "1 missing graphify: rc=$rc evals=$(evals): $out"

# 2. API key set -> exit 3, names variable
reset
out=$(PATH=$GOODPATH ANTHROPIC_API_KEY=x bash "$RUN" --yes 2>&1); rc=$?
if [ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -q 'ANTHROPIC_API_KEY'; then
  pass "2 API key set: exit 3, names variable, no eval"
else fail "2 API key: rc=$rc evals=$(evals): $out"; fi

# 2b. auth token set
reset
out=$(PATH=$GOODPATH ANTHROPIC_AUTH_TOKEN=x bash "$RUN" --yes 2>&1); rc=$?
if [ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -q 'ANTHROPIC_AUTH_TOKEN'; then
  pass "2b auth token set: exit 3, names variable, no eval"
else fail "2b auth token: rc=$rc evals=$(evals): $out"; fi

# 2c. graphify present, no claude
reset
out=$(PATH="$T/bin-noclaude:$SYSPATH" WARDEN_STUB_EXPECT_GRAPHIFY="$T/bin-noclaude/graphify" bash "$RUN" --yes 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -q "claude --version" && pass "2c missing claude: exit 3, no eval" || fail "2c missing claude: rc=$rc evals=$(evals): $out"

# 3. answer n -> no eval
reset
out=$(printf 'n\n' | PATH=$GOODPATH bash "$RUN" 2>&1); rc=$?
[ "$(evals)" -eq 0 ] && pass "3 answer n: no eval" || fail "3 answer n ran eval: rc=$rc"

# 4. cost line label
LABEL="list-price estimate; not billed on a subscription login, uses your plan's usage limits"
case "$out" in
  *"$LABEL"*) pass "4 cost line holds exact label" ;;
  *) fail "4 cost line label missing: $out" ;;
esac
case "$out" in
  *"Start 40 agents? [y/N]"*) pass "4 prompt names 40 agents" ;;
  *) fail "4 prompt 'Start 40 agents? [y/N]' missing" ;;
esac

# 5. --yes --runs 2: one eval per (arm ref, case) pair with exactly one --case, right flags, no --model
reset
out=$(PATH=$GOODPATH bash "$RUN" --yes --runs 2 2>&1); rc5=$?
ok=1
[ "$(evals)" -eq 8 ] || ok=0
while IFS= read -r line; do
  for f in '--no-publish' '--ablation none' '--scaffold' '--keep-temp' '--eval-dir warden-evals' '--runs 2' '--trust-plugin' '--allow-tools Bash'; do
    case "$line" in *"$f"*) ;; *) ok=0 ;; esac
  done
  case "$line" in *"--model"*) ok=0 ;; esac
  [ "$(printf '%s\n' "$line" | grep -o -- '--case ' | wc -l | tr -d ' ')" -eq 1 ] || ok=0
done <<EOF2
$(grep '^CALL eval' "$WARDEN_STUB_LOG")
EOF2
[ "$ok" -eq 1 ] && pass "5 one eval per (ref, case) with one --case, the pinned flags, no --model" || fail "5 eval calls wrong (rc=$rc5): $(cat "$WARDEN_STUB_LOG")"

# 6. record
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ -n "$rec" ]; then
  ok=1
  for p in 'Claude Code version' 'Model' 'graphify' 'Fixture tree hash' "$(git rev-parse c91be4c)" "$(git rev-parse 5a972be)" "$(git rev-parse 8199034)" '2.1.305' 'claude-stub-1' '9.9.9-stub' "$(git rev-parse HEAD:tests/behavior/evals/_fixture/storefront)" \
    '- Merge check: lib/merge_check.py' \
    'Runs measure attempts. Inside the eval sandbox on macOS, git, the home-installed Graphify binary, and `.git/config` writes are blocked, so `graphify-setup` and `graphify query` fail inside a run.'; do
    grep -qF -- "$p" "$rec" || { ok=0; echo "    missing: $p"; }
  done
  grep -qF 'list-price estimate' "$rec" || { ok=0; echo "    missing cost label"; }
  [ "$ok" -eq 1 ] && pass "6 record holds the five pins and the attempts statement" || fail "6 record incomplete"
  if grep -I -E '~/|/(Users|home|private|tmp|var)/' "$rec" >/dev/null; then
    fail "6 record holds a machine path: $(grep -I -E '~/|/(Users|home|private|tmp|var)/' "$rec" | head -n1)"
  else pass "6 record has no machine path"; fi
  if grep -F -e 'graphify query x' -e 'a.ts' "$rec" >/dev/null; then
    fail "6 record holds transcript text: $(grep -F -e 'graphify query x' -e 'a.ts' "$rec" | head -n1)"
  elif grep -E '^- read-order / candidate / run 1: graph_first=1 first=Bash;' "$rec" >/dev/null; then
    pass "6 record names the first tool, not its input"
  else fail "6 read-order run line lacks first=<tool>"; fi
else fail "6 no record written (rc=$rc5): $out"; fi

# 7. candidate planning 3 of 5 -> exit 1, FAIL in table (call 5 is the candidate ref's setup-planning call: c91be4c runs 4 cases first)
reset
out=$(PATH=$GOODPATH STUB_TRIG_5_SETUP_PLANNING=3 bash "$RUN" --yes 2>&1); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ "$rc" -eq 1 ] && [ -n "$rec" ] && grep -E '^\| *setup-planning.*FAIL' "$rec" >/dev/null; then
  pass "7 planning 3/5: exit 1 and table shows FAIL"
else fail "7 rc=$rc, record=${rec:-none}: $out"; fi
reset
PATH=$GOODPATH bash "$RUN" --yes >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "7 all criteria met: exit 0" || fail "7 default canned results should exit 0, got $rc"

# 7b. errored candidate runs fail an at-most case
reset
out=$(PATH=$GOODPATH STUB_ERR_6_SETUP_QUICK_QUESTION=2 STUB_ERR_TEXT="lost /private/tmp/e-Ab12/out" bash "$RUN" --yes 2>&1); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ "$rc" -eq 1 ] && [ -n "$rec" ] && grep -E '^\| *setup-quick-question \| candidate.*0/5 \(2 errored\).*FAIL' "$rec" >/dev/null \
   && grep -E 'setup-quick-question / candidate / run 1: errored \(lost <path>\)' "$rec" >/dev/null \
   && ! grep -F '/private/' "$rec" >/dev/null; then
  pass "7b errored runs: exit 1, table shows (2 errored) FAIL, run lines say errored, paths redacted"
else fail "7b rc=$rc: $out"; fi

# 7c. partial result -> exit 2
reset
out=$(PATH=$GOODPATH STUB_PARTIAL=1 bash "$RUN" --yes 2>&1); rc=$?
[ "$rc" -eq 2 ] && pass "7c partial result: exit 2" || fail "7c partial: rc=$rc: $out"

# 9. --arms and --record-dir
reset
printf 'read-order c91be4c 7d972fa at-least 4\n' > "$T/arms9.conf"
out=$(PATH=$GOODPATH bash "$RUN" --yes --arms "$T/arms9.conf" --record-dir "$T/other" 2>&1); rc=$?
if [ "$(evals)" -eq 2 ] && [ -n "$(ls "$T/other"/*.md 2>/dev/null)" ] && [ -z "$(ls "$T/runs"/*.md 2>/dev/null)" ]; then
  pass "9 --arms and --record-dir: 2 evals, record in the flag folder only"
else fail "9 rc=$rc evals=$(evals): $out"; fi
rm -rf "$T/other"

# 10. candidate only: agent count, one eval, no baseline row, no '-' pin
reset
printf 'read-order - 7d972fa at-least 4\n' > "$T/arms10.conf"
out=$(printf 'n\n' | PATH=$GOODPATH bash "$RUN" --arms "$T/arms10.conf" 2>&1); rc=$?
case "$out" in
  *"Start 5 agents? [y/N]"*) pass "10 candidate-only prompt names 5 agents" ;;
  *) fail "10 prompt 'Start 5 agents? [y/N]' missing: $out" ;;
esac
reset
out=$(PATH=$GOODPATH bash "$RUN" --yes --arms "$T/arms10.conf" 2>&1); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ "$(evals)" -eq 1 ] && [ -n "$rec" ] && grep -qF '| read-order | candidate |' "$rec" \
   && ! grep -qF '| read-order | baseline |' "$rec" && ! grep -qF ' - (' "$rec"; then
  pass "10 candidate only: 1 eval, candidate row only, no '-' pin"
else fail "10 rc=$rc evals=$(evals): $out"; fi

# 11. held-out grading
reset
printf 'read-order-heldout - 7d972fa at-least 4\n' > "$T/arms11.conf"
out11=$(PATH=$GOODPATH STUB_TRIG_1_READ_ORDER_HELDOUT=2 bash "$RUN" --yes --arms "$T/arms11.conf" 2>&1); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ "$rc" -eq 1 ] && [ -n "$rec" ] && grep -E '^\| read-order-heldout .*2/5.*graph-first >= 4.*FAIL' "$rec" >/dev/null \
   && grep -qF 'graph_first=' "$rec"; then
  pass "11 held-out graded by graph_first: exit 1, 2/5, FAIL"
else fail "11 rc=$rc: $out11"; fi

# 12. first commands on the terminal only
if printf '%s' "$out11" | grep -qF 'first commands: read-order-heldout / candidate / run 1' \
   && printf '%s' "$out11" | grep -qF 'Bash: graphify query x' \
   && [ -n "$rec" ] && ! grep -qF -e 'graphify query x' -e 'a.ts' "$rec"; then
  pass "12 first commands printed to the terminal, not the record"
else fail "12 first-commands print wrong: $out11"; fi

# 13. missing arms file
reset
out=$(PATH=$GOODPATH bash "$RUN" --yes --arms "$T/nope.conf" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'arms file not found' && [ "$(evals)" -eq 0 ]; then
  pass "13 missing arms file: exit 2, no eval"
else fail "13 rc=$rc evals=$(evals): $out"; fi

# 15. warden hooks merge. Synthetic arms are built with commit-tree from a temporary index; no ref is made.
OLD=$(git rev-parse 7ac111f)
W15="$T/w15"; mkdir -p "$W15"
WHJ='{"hooks":{"SessionStart":[{"matcher":"startup|clear|compact","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/code-map\" SessionStart"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/code-map\" SubagentStart"}]}]}}'
printf '%s\n' "$WHJ" > "$W15/hooks.json"
printf '%s\n' '{"name": "warden", "version": "0.0.0"}' > "$W15/plugin.json"
printf '%s\n' '{"name": "warden", "plugins": [{"name": "warden", "source": "./"}]}' > "$W15/marketplace.json"
printf '%s\n' 'Code map rule line.' > "$W15/code-map.md"
printf '%s\n' '#!/usr/bin/env bash' 'cat "$(dirname "$0")/code-map.md"' > "$W15/code-map"
printf '%s\n' 'collides' > "$W15/run-hook.cmd"
printf '%s\n' '# demo skill' > "$W15/demo-SKILL.md"
printf '%s\n' '{"extra": true}' > "$W15/extra.json"
printf '%s\n' '# not the real brainstorming skill' > "$W15/brainstorming-SKILL.md"
mkarm() { # mkarm <plain|hooks|extra|skill> -> prints commit sha. hooks collides on hooks/run-hook.cmd, extra adds an unexpected manifest file, skill collides on skills/brainstorming/SKILL.md
  local idx="$W15/index-$1" blob
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree "$OLD" || return 1
  add() { blob=$(git hash-object -w "$W15/$1") && GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "$2,$blob,$3"; }
  add plugin.json 100644 plugins/warden/.claude-plugin/plugin.json
  add marketplace.json 100644 plugins/warden/.claude-plugin/marketplace.json
  add hooks.json 100644 plugins/warden/hooks/hooks.json
  add code-map 100755 plugins/warden/hooks/code-map
  add code-map.md 100644 plugins/warden/hooks/code-map.md
  add demo-SKILL.md 100644 plugins/warden/skills/demo/SKILL.md
  [ "$1" = hooks ] && add run-hook.cmd 100644 plugins/warden/hooks/run-hook.cmd
  [ "$1" = extra ] && add extra.json 100644 plugins/warden/.claude-plugin/extra.json
  [ "$1" = skill ] && add brainstorming-SKILL.md 100644 plugins/warden/skills/brainstorming/SKILL.md
  local tree; tree=$(GIT_INDEX_FILE="$idx" git write-tree) || return 1
  git commit-tree "$tree" -p "$OLD" -m "synthetic warden arm $1"
}
WARM=$(mkarm plain); CARM=$(mkarm hooks); XARM=$(mkarm extra); SARM=$(mkarm skill)
printf 'setup-planning - %s at-least 4\n' "$OLD" > "$T/arms15a.conf"
printf 'setup-planning - %s at-least 4\n' "$WARM" > "$T/arms15b.conf"
printf 'setup-planning - %s at-least 4\n' "$CARM" > "$T/arms15c.conf"
printf 'setup-planning - %s at-least 4\n' "$XARM" > "$T/arms15d.conf"
printf 'setup-planning - %s at-least 4\n' "$SARM" > "$T/arms15e.conf"
snaprun() { reset; rm -rf "$T/snap"; PATH=$GOODPATH STUB_SNAPSHOT_DIR="$T/snap" bash "$RUN" --yes --runs 1 --arms "$1" 2>&1; }

# 15a. old arm: scratch tree equals git archive of plugins/superpowers
out=$(snaprun "$T/arms15a.conf"); rc=$?
rm -rf "$T/ref15a"; mkdir -p "$T/ref15a"; git archive "$OLD" plugins/superpowers | tar -x -C "$T/ref15a"
( cd "$T/snap/call-1" && find . -path ./warden-evals -prune -o -type f -print | sort ) > "$T/list15a.snap"
( cd "$T/ref15a/plugins/superpowers" && find . -type f | sort ) > "$T/list15a.ref"
if [ -s "$T/list15a.snap" ] && cmp -s "$T/list15a.snap" "$T/list15a.ref" && cmp -s "$T/snap/call-1/hooks/hooks.json" "$T/ref15a/plugins/superpowers/hooks/hooks.json"; then
  pass "15a old arm: same file list and hooks.json as git archive"
else fail "15a old arm differs (rc=$rc): $(diff "$T/list15a.snap" "$T/list15a.ref" | head -n3) $out"; fi

# 15b. warden arm: merged hooks.json, copied files, skills untouched
out=$(snaprun "$T/arms15b.conf"); rc=$?
rm -rf "$T/ref15b"; mkdir -p "$T/ref15b"; git archive "$WARM" plugins/superpowers | tar -x -C "$T/ref15b"
S="$T/snap/call-1"
if python3 -I - "$S/hooks/hooks.json" "$T/ref15b/plugins/superpowers/hooks/hooks.json" "$W15/hooks.json" <<'PY'
import json, sys
m, sp, w = (json.load(open(p))["hooks"] for p in sys.argv[1:4])
ss, sub = m["SessionStart"], m["SubagentStart"]
ok = (len(ss) == 2 and ss[0] == sp["SessionStart"][0] and ss[1] == w["SessionStart"][0]
      and sub == w["SubagentStart"] and set(m) == {"SessionStart", "SubagentStart"})
sys.exit(0 if ok else 1)
PY
then ok=1; else ok=0; fi
[ -f "$S/hooks/code-map" ] && [ -x "$S/hooks/code-map" ] && cmp -s "$S/hooks/code-map.md" "$W15/code-map.md" || ok=0
[ ! -e "$S/hooks/hooks.json.warden" ] && [ ! -e "$S/.claude-plugin/marketplace.json.warden" ] || ok=0
cmp -s "$S/skills/demo/SKILL.md" "$W15/demo-SKILL.md" || ok=0
diff -r "$T/ref15b/plugins/superpowers/skills" "$S/skills" 2>&1 | grep -v '^Only in '"$S"'/skills: demo' | grep -q . && ok=0
cmp -s "$S/.claude-plugin/plugin.json" "$T/ref15b/plugins/superpowers/.claude-plugin/plugin.json" || ok=0
cmp -s "$S/.claude-plugin/marketplace.json" "$T/ref15b/plugins/superpowers/.claude-plugin/marketplace.json" || ok=0
[ "$ok" -eq 1 ] && [ "$(evals)" -eq 1 ] && pass "15b warden arm: merged hooks.json, code-map files, skills equal" || fail "15b warden merge wrong (rc=$rc evals=$(evals)): $out"

# 15c. collision: exit 2, names the file, no eval
out=$(snaprun "$T/arms15c.conf"); rc=$?
if [ "$rc" -eq 2 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -qF 'merge collision:' && printf '%s' "$out" | grep -qF 'hooks/run-hook.cmd'; then
  pass "15c collision: exit 2, names hooks/run-hook.cmd, no eval"
else fail "15c collision rc=$rc evals=$(evals): $out"; fi

# 15d. unexpected warden manifest file: exit 2, names it, no eval
out=$(snaprun "$T/arms15d.conf"); rc=$?
if [ "$rc" -eq 2 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -qF 'unexpected warden manifest file: .claude-plugin/extra.json'; then
  pass "15d extra manifest file: exit 2, names .claude-plugin/extra.json, no eval"
else fail "15d extra manifest rc=$rc evals=$(evals): $out"; fi

# 15e. skill collides with Superpowers: exit 2, names it, no eval
out=$(snaprun "$T/arms15e.conf"); rc=$?
if [ "$rc" -eq 2 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -qF 'merge collision: skills/brainstorming/SKILL.md'; then
  pass "15e skill collision: exit 2, names skills/brainstorming/SKILL.md, no eval"
else fail "15e skill collision rc=$rc evals=$(evals): $out"; fi

# 15f. the wrapper acts on the checker's exit code. WARDEN_BEHAVIOR_MERGE_CHECK replaces lib/merge_check.py.
printf '%s\n' '#!/usr/bin/env bash' 'echo "merge incomplete: x" >&2' 'exit 2' > "$T/mc-fail"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$T/mc-ok"
chmod +x "$T/mc-fail" "$T/mc-ok"
out=$(WARDEN_BEHAVIOR_MERGE_CHECK="$T/mc-fail" snaprun "$T/arms15b.conf"); rc=$?
if [ "$rc" -eq 2 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -qF 'merge incomplete: x'; then
  pass "15f failing merge check: exit 2, message shown, no eval"
else fail "15f failing merge check rc=$rc evals=$(evals): $out"; fi

# 15g. test override: warning, STUB pin, STUB rows, never PASS, exit 1
out=$(WARDEN_BEHAVIOR_MERGE_CHECK="$T/mc-ok" snaprun "$T/arms15b.conf"); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
rows=$(grep -E '^\| setup-planning ' "$rec" 2>/dev/null)
if [ "$rc" -eq 1 ] && [ -n "$rec" ] && [ "$(evals)" -eq 1 ] \
   && printf '%s' "$out" | grep -qF 'warning: WARDEN_BEHAVIOR_MERGE_CHECK is set; this run is a test run and grades nothing' \
   && grep -qF -- '- Merge check: STUB' "$rec" \
   && [ -n "$rows" ] && ! printf '%s' "$rows" | grep -q 'PASS' \
   && [ "$(printf '%s\n' "$rows" | grep -vc '| STUB |$')" -eq 0 ]; then
  pass "15g merge check override: warning, STUB pin, STUB rows, no PASS, exit 1"
else fail "15g override rc=$rc evals=$(evals) rows=$rows: $out"; fi

# 15h. before and after: the old wrapper (7ac111f) and the changed wrapper build the same scratch plugin for the old arm
OLDW="$T/old/tests/behavior"; mkdir -p "$OLDW/lib"
git show "$OLD:tests/behavior/run-behavior" > "$OLDW/run-behavior" && chmod +x "$OLDW/run-behavior"
for f in $(git ls-tree --name-only "$OLD" tests/behavior/lib/); do git show "$OLD:$f" > "$OLDW/lib/$(basename "$f")"; done
cp -R "$HERE/../evals" "$OLDW/evals"
printf 'gitdir: %s\n' "$(git rev-parse --absolute-git-dir)" > "$T/old/.git"
reset; rm -rf "$T/snap-old" "$T/snap-new"
outo=$(PATH=$GOODPATH STUB_SNAPSHOT_DIR="$T/snap-old" bash "$OLDW/run-behavior" --yes --runs 1 --arms "$T/arms15a.conf" 2>&1); rco=$?
reset
outn=$(PATH=$GOODPATH STUB_SNAPSHOT_DIR="$T/snap-new" bash "$RUN" --yes --runs 1 --arms "$T/arms15a.conf" 2>&1); rcn=$?
if [ -d "$T/snap-old/call-1" ] && [ -d "$T/snap-new/call-1" ] && [ "$rco" -eq "$rcn" ] \
   && diff -r -x warden-evals "$T/snap-old/call-1" "$T/snap-new/call-1" >/dev/null; then
  pass "15h before and after: old wrapper and new wrapper build identical scratch plugins"
else fail "15h before/after differ (old rc=$rco, new rc=$rcn): $(diff -r -x warden-evals "$T/snap-old/call-1" "$T/snap-new/call-1" 2>&1 | head -n3) $outo $outn"; fi

# 16. trace cache: copy, guard, retention
printf 'read-order - %s at-least 1\n' "$OLD" > "$T/arms16.conf"
ARM16=$(printf '%s' "$OLD" | cut -c1-7)

# 16a. two runs leave two trace files under traces/<case>/<arm-sha7>/
reset
out=$(PATH=$GOODPATH bash "$RUN" --yes --runs 2 --arms "$T/arms16.conf" 2>&1); rc=$?
rid=$(ls "$WARDEN_BEHAVIOR_RAW_DIR" | head -n1)
td="$WARDEN_BEHAVIOR_RAW_DIR/$rid/traces/read-order/$ARM16"
if [ "$(ls "$td" 2>/dev/null | wc -l | tr -d ' ')" -eq 2 ] && [ -s "$td/run-1.jsonl" ] && [ -s "$td/run-2.jsonl" ] \
   && grep -q '"tool_use"' "$td/run-1.jsonl" && grep -q '"tool_use"' "$td/run-2.jsonl"; then
  pass "16a run folder holds 2 trace files with stub trace content"
else fail "16a traces missing (rc=$rc dir=$td): $(ls -R "$WARDEN_BEHAVIOR_RAW_DIR" 2>&1 | head -n8)"; fi

# 16b. trace cache inside a git work tree: exit 2 before any eval, names the variable
reset
mkdir -p "$T/gitcache" && git init -q "$T/gitcache"
out=$(PATH=$GOODPATH WARDEN_BEHAVIOR_RAW_DIR="$T/gitcache/sub/raw" bash "$RUN" --yes --runs 1 --arms "$T/arms16.conf" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -qF 'WARDEN_BEHAVIOR_RAW_DIR'; then
  pass "16b cache inside a git work tree: exit 2, names variable, no eval"
else fail "16b guard rc=$rc evals=$(evals): $out"; fi
rm -rf "$T/gitcache"

# 16c. 21 old run folders plus one new run: 20 remain, oldest gone; gate.sh and notes survive
reset
i=0
while [ "$i" -lt 21 ]; do
  d=$(printf '%06x' $((0xa00000 + i)))
  mkdir -p "$WARDEN_BEHAVIOR_RAW_DIR/$d"
  touch -t "$(printf '20200101%02d00' $((i + 1)))" "$WARDEN_BEHAVIOR_RAW_DIR/$d"
  i=$((i + 1))
done
printf 'x\n' > "$WARDEN_BEHAVIOR_RAW_DIR/gate.sh"; mkdir -p "$WARDEN_BEHAVIOR_RAW_DIR/notes"
touch -t 201901010000 "$WARDEN_BEHAVIOR_RAW_DIR/gate.sh" "$WARDEN_BEHAVIOR_RAW_DIR/notes"
out=$(PATH=$GOODPATH bash "$RUN" --yes --runs 1 --arms "$T/arms16.conf" 2>&1); rc=$?
nrun=$(ls "$WARDEN_BEHAVIOR_RAW_DIR" | grep -c '^[0-9a-f]\{6\}$')
if [ "$nrun" -eq 20 ] && [ ! -e "$WARDEN_BEHAVIOR_RAW_DIR/a00000" ] && [ ! -e "$WARDEN_BEHAVIOR_RAW_DIR/a00001" ] && [ -d "$WARDEN_BEHAVIOR_RAW_DIR/a00002" ]; then
  pass "16c retention keeps 20 run folders, oldest two gone"
else fail "16c retention nrun=$nrun rc=$rc: $(ls "$WARDEN_BEHAVIOR_RAW_DIR" | tr '\n' ' ')"; fi
if [ -f "$WARDEN_BEHAVIOR_RAW_DIR/gate.sh" ] && [ -d "$WARDEN_BEHAVIOR_RAW_DIR/notes" ]; then
  pass "16d gate.sh and notes survive retention"
else fail "16d non-run entries removed: $(ls "$WARDEN_BEHAVIOR_RAW_DIR" | tr '\n' ' ')"; fi

# 16e. record.py exits 2 (partial result): retention still runs, exit stays 2
reset
i=0
while [ "$i" -lt 21 ]; do
  d=$(printf '%06x' $((0xb00000 + i)))
  mkdir -p "$WARDEN_BEHAVIOR_RAW_DIR/$d"
  touch -t "$(printf '20200101%02d00' $((i + 1)))" "$WARDEN_BEHAVIOR_RAW_DIR/$d"
  i=$((i + 1))
done
out=$(PATH=$GOODPATH STUB_PARTIAL=1 bash "$RUN" --yes --runs 1 --arms "$T/arms16.conf" 2>&1); rc=$?
nrun=$(ls "$WARDEN_BEHAVIOR_RAW_DIR" | grep -c '^[0-9a-f]\{6\}$')
if [ "$rc" -eq 2 ] && [ "$nrun" -eq 20 ] && [ ! -e "$WARDEN_BEHAVIOR_RAW_DIR/b00000" ]; then
  pass "16e record.py exit 2: retention still keeps 20 run folders, exit 2"
else fail "16e rc=$rc nrun=$nrun: $(ls "$WARDEN_BEHAVIOR_RAW_DIR" | tr '\n' ' ')"; fi

# 8. repo untouched, no scratch left
STATUS_AFTER=$(git status --porcelain)
[ "$STATUS_BEFORE" = "$STATUS_AFTER" ] && pass "8 git status unchanged" || fail "8 git status changed"
[ "$REFS_BEFORE" = "$(git for-each-ref)" ] && pass "8 git for-each-ref unchanged" || fail "8 refs changed"
left=$(ls -A "$T/tmp")
[ -z "$left" ] && pass "8 no scratch dir left" || fail "8 scratch left: $left"

# 14. no bytecode left beside the grader. record.py loads graph_first.py with importlib;
# the default python3 (not /usr/bin/python3, which never writes bytecode) must not leave __pycache__.
rm -rf tests/behavior/lib/__pycache__
mkdir -p "$T/r14"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$T/r14/trace.jsonl"
SHA14=$(git rev-parse HEAD)
printf 'read-order - %s at-least 1\n' "$SHA14" > "$T/r14/conf"
printf '{"claudeVersion":"x","cases":[{"name":"read-order","arms":{"with":[{"tracePath":"%s"}]}}]}' "$T/r14/trace.jsonl" > "$T/r14/result.json"
python3 -I tests/behavior/lib/record.py --conf "$T/r14/conf" --out-dir "$T/r14/out" --runs 1 --graphify-version x \
  --fixture-hash y --id t14 --result "$SHA14=$T/r14/result.json" >/dev/null 2>&1
if [ -e tests/behavior/lib/__pycache__ ]; then
  fail "14 record.py left tests/behavior/lib/__pycache__"; rm -rf tests/behavior/lib/__pycache__
else pass "14 no bytecode left in tests/behavior/lib"; fi

[ "$FAILURES" -eq 0 ]
