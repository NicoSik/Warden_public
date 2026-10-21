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
mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/bin-noclaude" "$T/runs" "$T/raw"
ln -s "$STUBS/claude" "$T/bin/claude"
ln -s "$STUBS/graphify" "$T/bin/graphify"
ln -s "$STUBS/claude" "$T/bin-noclaude/claude"

export HOME="$T/home" TMPDIR="$T/tmp" STUB_TMP="$T/tmp"
export WARDEN_STUB_LOG="$T/stub.log"
export WARDEN_STUB_EXPECT_CLAUDE="$T/bin/claude"
export WARDEN_STUB_EXPECT_GRAPHIFY="$T/bin/graphify"
export WARDEN_BEHAVIOR_RECORD_DIR="$T/runs"
export WARDEN_BEHAVIOR_RAW_DIR="$T/raw"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
GOODPATH="$T/bin:$SYSPATH"

[ "$(PATH=$GOODPATH command -v claude)" = "$T/bin/claude" ] || { echo "stub not first on PATH"; exit 1; }

reset() { : > "$WARDEN_STUB_LOG"; rm -f "$WARDEN_STUB_LOG.count"; rm -rf "$T/runs" "$T/raw"; mkdir -p "$T/runs" "$T/raw"; }
evals() { grep -c '^CALL eval' "$WARDEN_STUB_LOG"; }

cd "$HERE/../../.." || exit 1
STATUS_BEFORE=$(git status --porcelain)

# 1. no graphify -> exit 3, no eval
reset
out=$(PATH="$T/bin-noclaude:$SYSPATH" bash "$RUN" --yes 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && pass "1 missing graphify: exit 3, no eval" || fail "1 missing graphify: rc=$rc evals=$(evals): $out"

# 2. API key set -> exit 3, names variable
reset
out=$(PATH=$GOODPATH ANTHROPIC_API_KEY=x bash "$RUN" --yes 2>&1); rc=$?
if [ "$rc" -eq 3 ] && [ "$(evals)" -eq 0 ] && printf '%s' "$out" | grep -q 'ANTHROPIC_API_KEY'; then
  pass "2 API key set: exit 3, names variable, no eval"
else fail "2 API key: rc=$rc evals=$(evals): $out"; fi

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

# 5. --yes --runs 2: one eval per distinct arm ref, right flags, no --model
reset
out=$(PATH=$GOODPATH bash "$RUN" --yes --runs 2 2>&1); rc5=$?
ok=1
[ "$(evals)" -eq 3 ] || ok=0
while IFS= read -r line; do
  for f in '--no-publish' '--ablation none' '--scaffold' '--keep-temp' '--eval-dir warden-evals' '--runs 2' '--trust-plugin' '--allow-tools Bash'; do
    case "$line" in *"$f"*) ;; *) ok=0 ;; esac
  done
  case "$line" in *"--model"*) ok=0 ;; esac
done <<EOF2
$(grep '^CALL eval' "$WARDEN_STUB_LOG")
EOF2
[ "$ok" -eq 1 ] && pass "5 one eval per arm ref with the pinned flags, no --model" || fail "5 eval calls wrong (rc=$rc5): $(cat "$WARDEN_STUB_LOG")"

# 6. record
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ -n "$rec" ]; then
  ok=1
  for p in 'Claude Code version' 'Model' 'graphify' 'Fixture tree hash' "$(git rev-parse c91be4c)" "$(git rev-parse 5a972be)" "$(git rev-parse 8199034)" '2.1.305' 'account default' '9.9.9-stub' "$(git rev-parse HEAD:tests/behavior/evals/_fixture/storefront)" \
    'Runs measure attempts. Inside the eval sandbox on macOS, git, the home-installed Graphify binary, and `.git/config` writes are blocked, so `graphify-setup` and `graphify query` fail inside a run.'; do
    grep -qF -- "$p" "$rec" || { ok=0; echo "    missing: $p"; }
  done
  grep -qF 'list-price estimate' "$rec" || { ok=0; echo "    missing cost label"; }
  [ "$ok" -eq 1 ] && pass "6 record holds the five pins and the attempts statement" || fail "6 record incomplete"
  if grep -I -E '/(Users|home)/[A-Za-z0-9._-]+' "$rec" >/dev/null; then
    fail "6 record holds a machine path"
  else pass "6 record has no machine path"; fi
else fail "6 no record written (rc=$rc5): $out"; fi

# 7. candidate planning 3 of 5 -> exit 1, FAIL in table (call 2 is the candidate ref of the setup cases)
reset
out=$(PATH=$GOODPATH STUB_TRIG_2_SETUP_PLANNING=3 bash "$RUN" --yes 2>&1); rc=$?
rec=$(ls "$T/runs"/*.md 2>/dev/null | head -n1)
if [ "$rc" -eq 1 ] && [ -n "$rec" ] && grep -E '^\| *setup-planning.*FAIL' "$rec" >/dev/null; then
  pass "7 planning 3/5: exit 1 and table shows FAIL"
else fail "7 rc=$rc, record=${rec:-none}: $out"; fi
reset
PATH=$GOODPATH bash "$RUN" --yes >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "7 all criteria met: exit 0" || fail "7 default canned results should exit 0, got $rc"

# 8. repo untouched, no scratch left
STATUS_AFTER=$(git status --porcelain)
[ "$STATUS_BEFORE" = "$STATUS_AFTER" ] && pass "8 git status unchanged" || fail "8 git status changed"
left=$(ls -A "$T/tmp")
[ -z "$left" ] && pass "8 no scratch dir left" || fail "8 scratch left: $left"

[ "$FAILURES" -eq 0 ]
