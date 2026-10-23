#!/usr/bin/env bash
# Tests for plugins/warden/scripts/graphify-setup.
# The main cases use a fake graphify on PATH and run offline. A final section
# runs against the real graphify CLI when one is installed, and is skipped otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/warden/scripts/graphify-setup"
REAL_GRAPHIFY="$(command -v graphify 2>/dev/null || true)"

FAILURES=0
TEST_ROOT="$(mktemp -d)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
FAKE_BIN="$TEST_ROOT/fake-bin"
EMPTY_BIN="$TEST_ROOT/empty-bin"
export FAKE_LOG="$TEST_ROOT/fake.log"
export XDG_CACHE_HOME="$TEST_ROOT/cache"
export GIT_CONFIG_NOSYSTEM=1
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME" "$EMPTY_BIN"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
GIT_DIR_BIN="$(dirname "$(command -v git)")"
SYSTEM_PATH="$GIT_DIR_BIN:$SYSTEM_PATH"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  [PASS] $1"
}

fail() {
  echo "  [FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_true() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_false() {
  local description="$1"
  shift
  if "$@"; then
    fail "$description"
  else
    pass "$description"
  fi
}

# A fake graphify that records its calls. FAKE_GRAPHIFY_FAIL selects a failure:
# version, update, update-empty, hook, or hook-noop.
make_fake_graphify() {
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/graphify" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
mode="${FAKE_GRAPHIFY_FAIL:-}"
case "$1" in
  --version)
    [[ "$mode" == "version" ]] && exit 1
    echo "graphify 0.0.0-fake"
    ;;
  update)
    [[ "$mode" == "update" ]] && { mkdir -p graphify-out; echo "partial" >graphify-out/partial; printf '{"half' >graphify-out/graph.json; echo x >graphify-out/graph.json.tmp; exit 1; }
    mkdir -p graphify-out
    [[ "$mode" == "update-empty" ]] && exit 0
    echo '{"nodes":[]}' >graphify-out/graph.json
    ;;
  hook)
    if [[ "$2" == "uninstall" ]]; then
      dir="$(git rev-parse --git-path hooks)"
      [[ "$(basename "$dir")" == "_" ]] && dir="$(dirname "$dir")"
      if [[ -f "$dir/post-commit" ]]; then
        sed '/# graphify-hook-start/,/# graphify-hook-end/d' "$dir/post-commit" >"$dir/post-commit.tmp"
        cat "$dir/post-commit.tmp" >"$dir/post-commit" && rm -f "$dir/post-commit.tmp"
        [[ "$(grep -cv '^#!' "$dir/post-commit" | tr -d ' ')" == "0" ]] && rm -f "$dir/post-commit"
      fi
      exit 0
    fi
    [[ "$2" == "install" ]] || exit 2
    if [[ "$mode" == "hook" ]]; then
      dir="$(git rev-parse --git-path hooks)"
      printf '#!/bin/sh\n# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$dir/post-commit"
      chmod 755 "$dir/post-commit"
      printf 'graphify-out/graph.json merge=graphify\n' >>.gitattributes
      echo "boom" >&2
      exit 1
    fi
    [[ "$mode" == "hook-noop" ]] && exit 0
    dir="$(git rev-parse --git-path hooks)"
    [[ "$(basename "$dir")" == "_" ]] && dir="$(dirname "$dir")"
    mkdir -p "$dir"
    if [[ -f "$dir/post-commit" ]]; then
      printf '\n# graphify-hook-start\ntrue\n# graphify-hook-end\n' >>"$dir/post-commit"
    else
      printf '#!/bin/sh\n# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$dir/post-commit"
      chmod 755 "$dir/post-commit"
    fi
    printf 'graphify-out/graph.json merge=graphify\n' >>.gitattributes
    [[ "$mode" == "hook-lock" ]] && { touch "$(git rev-parse --git-common-dir)/config.lock"; exit 0; }
    git config merge.graphify.name "graphify graph.json union merge"
    git config merge.graphify.driver "graphify merge-driver %O %A %B"
    ;;
  *)
    exit 2
    ;;
esac
FAKE
  chmod +x "$FAKE_BIN/graphify"
}

# Create a committed repo with N tracked source files plus one README.
make_repo() {
  local dir="$1"
  local count="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  local i
  for ((i = 1; i <= count; i++)); do
    echo "x = $i" >"$dir/mod$i.py"
  done
  echo "readme" >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

# Run the script in a repo. Sets OUT, ERR and RC.
run_in() {
  local dir="$1"
  local path="$2"
  shift 2
  local out_file="$TEST_ROOT/out" err_file="$TEST_ROOT/err"
  (cd "$dir" && PATH="$path" "$SCRIPT_UNDER_TEST" "$@") >"$out_file" 2>"$err_file"
  RC=$?
  OUT="$(cat "$out_file")"
  ERR="$(cat "$err_file")"
}

with_fake() {
  echo "$FAKE_BIN:$SYSTEM_PATH"
}

without_cli() {
  echo "$EMPTY_BIN:$SYSTEM_PATH"
}

count_lines() {
  grep -cxF "$2" "$1" 2>/dev/null || true
}

# Print the previous state of a repo: config value, ignore and attribute files,
# graphify-out/, the hooks, merge.graphify.* and the notice marker.
snapshot_state() {
  local dir="$1" f
  echo "warden.graphify: $(git -C "$dir" config --local --get warden.graphify 2>/dev/null || echo absent)"
  git -C "$dir" config --local --get-regexp '^warden\.' 2>/dev/null | LC_ALL=C sort || true
  for f in .gitignore .gitattributes; do
    if [[ -e "$dir/$f" ]]; then
      echo "$f: $(shasum "$dir/$f" | cut -d' ' -f1)"
    else
      echo "$f: absent"
    fi
  done
  if [[ -d "$dir/graphify-out" ]]; then
    echo "graphify-out: present"
    (cd "$dir/graphify-out" && find . | LC_ALL=C sort && find . -type f -exec shasum {} + | LC_ALL=C sort -k2)
  else
    echo "graphify-out: absent"
  fi
  (cd "$dir/.git/hooks" && find . -type f -exec shasum {} + | LC_ALL=C sort -k2)
  git -C "$dir" config --local --get-regexp '^merge\.graphify\.' 2>/dev/null || true
  if [[ -e "$XDG_CACHE_HOME/warden/graphify-install-mentioned" ]]; then echo "marker: present"; else echo "marker: absent"; fi
  if [[ -e "$XDG_CACHE_HOME/warden" ]]; then echo "marker folder: present"; else echo "marker folder: absent"; fi
}

# Compare the state now with a snapshot taken before.
assert_unchanged() {
  local dir="$1" before="$2" description="$3"
  assert_eq "$(snapshot_state "$dir")" "$before" "$description"
}

BLOCK_GIT="graphify-setup: cannot run here: git does not run in this shell. Nothing was changed."
BLOCK_GRAPHIFY="graphify-setup: cannot run here: graphify does not run in this shell. Nothing was changed."
BLOCK_CONFIG="graphify-setup: cannot run here: .git/config is not writable. Nothing was changed."

# Make git refuse writes to the local config. A leftover config.lock makes git
# fail the way a write-protected .git/config does in a sandbox. (chmod a-w on
# .git/config alone does not stop git: it writes a lock file and renames it.)
block_config() { : >"$1/.git/config.lock"; }
unblock_config() { rm -f "$1/.git/config.lock"; }

make_fake_graphify

echo "Test: script exists and is executable"
assert_true "graphify-setup is executable" test -x "$SCRIPT_UNDER_TEST"

echo "Test: usage errors"
make_repo "$TEST_ROOT/usage" 20
run_in "$TEST_ROOT/usage" "$(with_fake)"
assert_eq "$RC" "2" "no argument exits 2"
run_in "$TEST_ROOT/usage" "$(with_fake)" bogus
assert_eq "$RC" "2" "unknown command exits 2"
assert_eq "$ERR" "graphify-setup: unknown command: bogus" "error message does not include the exit code"
mkdir -p "$TEST_ROOT/not-a-repo"
run_in "$TEST_ROOT/not-a-repo" "$(with_fake)" status
assert_eq "$RC" "2" "status outside a git repo exits 2"
assert_eq "$OUT" "" "status outside a git repo prints nothing on stdout"

echo "Test: 19/20 tracked source file boundary"
make_repo "$TEST_ROOT/r19" 19
make_repo "$TEST_ROOT/r20" 20
run_in "$TEST_ROOT/r19" "$(with_fake)" status
assert_eq "$OUT" "small" "19 tracked source files -> small"
run_in "$TEST_ROOT/r20" "$(with_fake)" status
assert_eq "$OUT" "ask" "20 tracked source files -> ask"
assert_eq "$RC" "0" "status exits 0"
for i in 1 2 3 4 5; do echo "untracked" >"$TEST_ROOT/r19/extra$i.py"; done
run_in "$TEST_ROOT/r19" "$(with_fake)" status
assert_eq "$OUT" "small" "untracked source files do not count"

echo "Test: no-cli"
run_in "$TEST_ROOT/r20" "$(without_cli)" status
assert_eq "$OUT" "no-cli" "missing graphify -> no-cli"
run_in "$TEST_ROOT/r19" "$(without_cli)" status
assert_eq "$OUT" "small" "small wins over no-cli"
before="$(snapshot_state "$TEST_ROOT/r20")"
FAKE_GRAPHIFY_FAIL=version run_in "$TEST_ROOT/r20" "$(with_fake)" status
assert_eq "$OUT" "unavailable" "graphify present but failing --version -> unavailable"
assert_eq "$RC" "4" "graphify present but failing --version: status exits 4"
assert_eq "$ERR" "graphify-setup: cannot run here: graphify does not run in this shell. Nothing was changed." "graphify present but failing --version: graphify blocked message"
assert_eq "$(snapshot_state "$TEST_ROOT/r20")" "$before" "graphify present but failing --version: state unchanged"
FAKE_GRAPHIFY_FAIL=version run_in "$TEST_ROOT/r19" "$(with_fake)" status
assert_eq "$OUT" "small" "small still wins over a failing graphify"
run_in "$TEST_ROOT/r20" "$(without_cli)" status
assert_eq "$OUT" "no-cli" "graphify absent from PATH -> no-cli, exit 0"
assert_eq "$RC" "0" "graphify absent: status exits 0"

echo "Test: decline is stored in local git config and persists"
make_repo "$TEST_ROOT/dec" 20
run_in "$TEST_ROOT/dec" "$(with_fake)" decline
assert_eq "$RC" "0" "decline exits 0"
assert_eq "$(git -C "$TEST_ROOT/dec" config --local --get warden.graphify)" "declined" "decline writes warden.graphify=declined to local config"
assert_eq "$(git -C "$TEST_ROOT/dec" status --porcelain)" "" "decline changes no file in the work tree"
run_in "$TEST_ROOT/dec" "$(with_fake)" status
assert_eq "$OUT" "declined" "status after decline -> declined"
run_in "$TEST_ROOT/dec" "$(without_cli)" status
assert_eq "$OUT" "declined" "declined wins over no-cli"
git -C "$TEST_ROOT/dec" worktree add -q "$TEST_ROOT/dec-wt" -b side 2>/dev/null
run_in "$TEST_ROOT/dec-wt" "$(with_fake)" status
assert_eq "$OUT" "declined" "decline applies to a linked worktree of the same repo"
make_repo "$TEST_ROOT/dec-small" 3
run_in "$TEST_ROOT/dec-small" "$(with_fake)" decline
run_in "$TEST_ROOT/dec-small" "$(with_fake)" status
assert_eq "$OUT" "declined" "declined wins over small"

echo "Test: graph.json alone is not ready"
make_repo "$TEST_ROOT/graph-only" 20
mkdir -p "$TEST_ROOT/graph-only/graphify-out"
echo '{}' >"$TEST_ROOT/graph-only/graphify-out/graph.json"
run_in "$TEST_ROOT/graph-only" "$(with_fake)" status
assert_eq "$OUT" "ask" "graph.json without hooks or a setup record -> ask"

echo "Test: setup in a default repo"
make_repo "$TEST_ROOT/s1" 20
printf 'node_modules/\n*.log' >"$TEST_ROOT/s1/.gitignore"
printf '*.png binary\n' >"$TEST_ROOT/s1/.gitattributes"
git -C "$TEST_ROOT/s1" add -A && git -C "$TEST_ROOT/s1" commit -q -m attrs
echo "user edit" >>"$TEST_ROOT/s1/mod1.py"
echo "staged edit" >>"$TEST_ROOT/s1/mod2.py"
git -C "$TEST_ROOT/s1" add mod2.py
head_before="$(git -C "$TEST_ROOT/s1" rev-parse HEAD)"
index_before="$(git -C "$TEST_ROOT/s1" diff --cached)"
mod1_before="$(cat "$TEST_ROOT/s1/mod1.py")"
attrs_before="$(cat "$TEST_ROOT/s1/.gitattributes")"
: >"$FAKE_LOG"
run_in "$TEST_ROOT/s1" "$(with_fake)" setup
assert_eq "$RC" "0" "setup exits 0"
assert_true "setup builds graphify-out/graph.json" test -f "$TEST_ROOT/s1/graphify-out/graph.json"
assert_true "setup installs an executable post-commit hook" test -x "$TEST_ROOT/s1/.git/hooks/post-commit"
assert_true "post-commit hook holds the graphify block" grep -qF "# graphify-hook-start" "$TEST_ROOT/s1/.git/hooks/post-commit"
assert_eq "$(count_lines "$TEST_ROOT/s1/.gitignore" "graphify-out/")" "1" ".gitignore lists graphify-out/ once"
assert_eq "$(head -n 2 "$TEST_ROOT/s1/.gitignore")" "$(printf 'node_modules/\n*.log')" "existing .gitignore lines are kept"
assert_eq "$(cat "$TEST_ROOT/s1/.gitattributes")" "$attrs_before" ".gitattributes is restored after hook install"
assert_eq "$(git -C "$TEST_ROOT/s1" config --get-regexp '^merge\.graphify\.' || true)" "" "merge.graphify.* keys added by hook install are removed"
assert_eq "$(git -C "$TEST_ROOT/s1" rev-parse HEAD)" "$head_before" "setup makes no commit"
assert_eq "$(git -C "$TEST_ROOT/s1" diff --cached)" "$index_before" "setup leaves the index unchanged"
assert_eq "$(cat "$TEST_ROOT/s1/mod1.py")" "$mod1_before" "setup leaves unstaged user edits unchanged"
assert_eq "$(git -C "$TEST_ROOT/s1" status --porcelain | sort | tr '\n' ' ')" "$(printf ' M .gitignore\n M mod1.py\nM  mod2.py\n' | sort | tr '\n' ' ')" "only .gitignore changes besides the user's own edits"
assert_eq "$(git -C "$TEST_ROOT/s1" config --local --get warden.graphify)" "enabled" "setup records warden.graphify=enabled"
assert_eq "$(grep -c '^update \.$' "$FAKE_LOG")" "1" "setup runs graphify update . once"
assert_eq "$(grep -c '^hook install$' "$FAKE_LOG")" "1" "setup runs graphify hook install once"
run_in "$TEST_ROOT/s1" "$(with_fake)" status
assert_eq "$OUT" "ready" "status after setup -> ready"
run_in "$TEST_ROOT/s1" "$(without_cli)" status
assert_eq "$OUT" "no-cli" "ready needs a working CLI"

echo "Test: setup twice adds no duplicate entries"
: >"$FAKE_LOG"
run_in "$TEST_ROOT/s1" "$(with_fake)" setup
assert_eq "$RC" "0" "second setup exits 0"
assert_eq "$(count_lines "$TEST_ROOT/s1/.gitignore" "graphify-out/")" "1" ".gitignore still lists graphify-out/ once"
assert_eq "$(grep -c '^hook install$' "$FAKE_LOG")" "0" "second setup does not rerun hook install when the hook is active"
assert_eq "$(grep -c 'graphify-hook-start' "$TEST_ROOT/s1/.git/hooks/post-commit")" "1" "post-commit holds one graphify block"
assert_eq "$(cat "$TEST_ROOT/s1/.gitattributes")" "$attrs_before" ".gitattributes is still unchanged after the second setup"

echo "Test: setup keeps an existing equivalent .gitignore entry"
make_repo "$TEST_ROOT/s2" 20
printf '/graphify-out\n' >"$TEST_ROOT/s2/.gitignore"
run_in "$TEST_ROOT/s2" "$(with_fake)" setup
assert_eq "$(cat "$TEST_ROOT/s2/.gitignore")" "/graphify-out" "/graphify-out counts as already listed"
make_repo "$TEST_ROOT/s3" 20
run_in "$TEST_ROOT/s3" "$(with_fake)" setup
assert_eq "$(cat "$TEST_ROOT/s3/.gitignore")" "graphify-out/" "missing .gitignore is created with one line"
assert_false "no .gitattributes is left behind when there was none" test -e "$TEST_ROOT/s3/.gitattributes"

echo "Test: setup keeps an existing post-commit hook"
make_repo "$TEST_ROOT/s4" 20
printf '#!/bin/sh\necho user-hook\n' >"$TEST_ROOT/s4/.git/hooks/post-commit"
chmod 755 "$TEST_ROOT/s4/.git/hooks/post-commit"
run_in "$TEST_ROOT/s4" "$(with_fake)" setup
assert_eq "$RC" "0" "setup with an existing hook exits 0"
assert_true "user hook line survives" grep -qx "echo user-hook" "$TEST_ROOT/s4/.git/hooks/post-commit"

echo "Test: setup refuses a non-executable post-commit hook"
make_repo "$TEST_ROOT/s5" 20
printf '#!/bin/sh\necho user-hook\n' >"$TEST_ROOT/s5/.git/hooks/post-commit"
chmod 644 "$TEST_ROOT/s5/.git/hooks/post-commit"
run_in "$TEST_ROOT/s5" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when git will not run the hook"
assert_true "error names the inactive hook" grep -q "did not leave an active post-commit hook" <<<"$ERR"
assert_true "user hook line survives the rollback" grep -qx "echo user-hook" "$TEST_ROOT/s5/.git/hooks/post-commit"
assert_false "graphify block is rolled back from the user's hook" grep -qF "graphify-hook-start" "$TEST_ROOT/s5/.git/hooks/post-commit"
assert_eq "$(git -C "$TEST_ROOT/s5" status --porcelain)" "" "after the failure the work tree is unchanged (.gitignore rolled back)"
run_in "$TEST_ROOT/s5" "$(with_fake)" status
assert_eq "$OUT" "ask" "status stays ask after the failed setup"

echo "Test: graph build failure"
make_repo "$TEST_ROOT/f1" 20
FAKE_GRAPHIFY_FAIL=update run_in "$TEST_ROOT/f1" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when graphify update fails"
assert_true "error says the build failed" grep -q "graph build failed" <<<"$ERR"
assert_false "partial graphify-out/ is removed" test -e "$TEST_ROOT/f1/graphify-out"
assert_false ".gitignore is not created" test -e "$TEST_ROOT/f1/.gitignore"
assert_eq "$(git -C "$TEST_ROOT/f1" status --porcelain)" "" "work tree is clean after the failure"
run_in "$TEST_ROOT/f1" "$(with_fake)" status
assert_eq "$OUT" "ask" "status stays ask after a failed build"
make_repo "$TEST_ROOT/f1b" 20
mkdir -p "$TEST_ROOT/f1b/graphify-out" && echo keep >"$TEST_ROOT/f1b/graphify-out/notes"
echo '{"old":1}' >"$TEST_ROOT/f1b/graphify-out/graph.json"
before="$(snapshot_state "$TEST_ROOT/f1b")"
FAKE_GRAPHIFY_FAIL=update run_in "$TEST_ROOT/f1b" "$(with_fake)" setup
assert_true "a graphify-out/ that existed before is kept" test -f "$TEST_ROOT/f1b/graphify-out/notes"
assert_eq "$RC" "1" "failing build over an existing graphify-out/ exits 1"
assert_unchanged "$TEST_ROOT/f1b" "$before" "failing build restores the previous graphify-out/ byte for byte"
assert_eq "$(cat "$TEST_ROOT/f1b/graphify-out/graph.json")" '{"old":1}' "previous graph.json is back"
assert_false "no half-written graph.json.tmp is left" test -e "$TEST_ROOT/f1b/graphify-out/graph.json.tmp"
make_repo "$TEST_ROOT/f1c" 20
FAKE_GRAPHIFY_FAIL=update-empty run_in "$TEST_ROOT/f1c" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when update succeeds but writes no graph.json"

echo "Test: hook install failure"
make_repo "$TEST_ROOT/f2" 20
printf '*.png binary\n' >"$TEST_ROOT/f2/.gitattributes"
FAKE_GRAPHIFY_FAIL=hook run_in "$TEST_ROOT/f2" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when graphify hook install fails"
assert_true "error says hook install failed" grep -q "hook install failed" <<<"$ERR"
assert_eq "$(cat "$TEST_ROOT/f2/.gitattributes")" "*.png binary" ".gitattributes is restored after a failed hook install"
assert_true "error names the recovery step" grep -q "rerun setup" <<<"$ERR"
assert_false "the failed hook install is rolled back" test -e "$TEST_ROOT/f2/.git/hooks/post-commit"
assert_eq "$(git -C "$TEST_ROOT/f2" status --porcelain | sort | tr '\n' ' ')" "?? .gitattributes " "only the pre-existing .gitattributes is new after a failed hook install"
assert_eq "$(git -C "$TEST_ROOT/f2" config --get-regexp '^merge\.graphify\.' || true)" "" "no merge.graphify.* keys after a failed hook install"
assert_false "no setup record after a failed hook install" git -C "$TEST_ROOT/f2" config --get warden.graphify
run_in "$TEST_ROOT/f2" "$(with_fake)" status
assert_eq "$OUT" "ask" "status stays ask after a failed hook install"
make_repo "$TEST_ROOT/f3" 20
FAKE_GRAPHIFY_FAIL=hook-noop run_in "$TEST_ROOT/f3" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when hook install reports success but writes no hook"
assert_eq "$(git -C "$TEST_ROOT/f3" status --porcelain)" "" "no-op hook install leaves the work tree unchanged"

echo "Test: pre-existing merge.graphify keys are kept"
make_repo "$TEST_ROOT/mk" 20
git -C "$TEST_ROOT/mk" config merge.graphify.driver "my own driver"
run_in "$TEST_ROOT/mk" "$(with_fake)" setup
assert_eq "$(git -C "$TEST_ROOT/mk" config --get merge.graphify.driver)" "my own driver" "a key that existed keeps its original value"
assert_false "a key that did not exist is removed" git -C "$TEST_ROOT/mk" config --get merge.graphify.name

echo "Test: GRAPHIFY_OUT pointing elsewhere"
make_repo "$TEST_ROOT/go" 20
GRAPHIFY_OUT=.cache-graph run_in "$TEST_ROOT/go" "$(with_fake)" setup
assert_eq "$RC" "1" "setup exits 1 when GRAPHIFY_OUT names another directory"
assert_true "error names GRAPHIFY_OUT" grep -q "GRAPHIFY_OUT" <<<"$ERR"
assert_eq "$(git -C "$TEST_ROOT/go" status --porcelain)" "" "nothing changes when GRAPHIFY_OUT is set"
GRAPHIFY_OUT=graphify-out run_in "$TEST_ROOT/go" "$(with_fake)" setup
assert_eq "$RC" "0" "GRAPHIFY_OUT=graphify-out is accepted"
make_repo "$TEST_ROOT/go2" 20
GRAPHIFY_OUT='' run_in "$TEST_ROOT/go2" "$(with_fake)" setup
assert_eq "$RC" "0" "empty GRAPHIFY_OUT is treated as unset, as graphify does"
make_repo "$TEST_ROOT/go3" 20
GRAPHIFY_OUT=graphify-out/ run_in "$TEST_ROOT/go3" "$(with_fake)" setup
assert_eq "$RC" "0" "GRAPHIFY_OUT=graphify-out/ is accepted"
make_repo "$TEST_ROOT/go4" 20
GRAPHIFY_OUT=/tmp/elsewhere run_in "$TEST_ROOT/go4" "$(with_fake)" setup
assert_eq "$RC" "1" "absolute GRAPHIFY_OUT is refused"
assert_false "refused setup writes no graphify-out/" test -e "$TEST_ROOT/go4/graphify-out"

echo "Test: equivalent .gitignore patterns"
for pattern in 'graphify-out/*' '**/graphify-out/' '**/graphify-out'; do
  make_repo "$TEST_ROOT/gi" 20
  printf '%s\n' "$pattern" >"$TEST_ROOT/gi/.gitignore"
  run_in "$TEST_ROOT/gi" "$(with_fake)" setup
  assert_eq "$(cat "$TEST_ROOT/gi/.gitignore")" "$pattern" "$pattern counts as already listed"
  rm -rf "$TEST_ROOT/gi"
done

echo "Test: linked worktrees"
make_repo "$TEST_ROOT/wt-main" 20
run_in "$TEST_ROOT/wt-main" "$(with_fake)" setup
git -C "$TEST_ROOT/wt-main" worktree add -q "$TEST_ROOT/wt-a" -b feature-a
run_in "$TEST_ROOT/wt-a" "$(with_fake)" status
assert_eq "$OUT" "build" "worktree of a set-up repo without a graph -> build, not ask"
: >"$FAKE_LOG"
run_in "$TEST_ROOT/wt-a" "$(with_fake)" setup
assert_eq "$RC" "3" "setup in a linked worktree exits 3 (hooks do not run in worktrees)"
assert_eq "$(grep -c '^hook install$' "$FAKE_LOG")" "0" "setup in a linked worktree does not run hook install"
assert_true "setup in a linked worktree builds the graph there" test -f "$TEST_ROOT/wt-a/graphify-out/graph.json"
assert_eq "$(git -C "$TEST_ROOT/wt-main" config --get warden.graphify)" "enabled" "setup in a worktree keeps the shared enabled record"
run_in "$TEST_ROOT/wt-a" "$(with_fake)" status
assert_eq "$OUT" "ready" "worktree with its own graph -> ready"
make_repo "$TEST_ROOT/wt2-main" 20
git -C "$TEST_ROOT/wt2-main" worktree add -q "$TEST_ROOT/wt2-a" -b feature-a
run_in "$TEST_ROOT/wt2-a" "$(with_fake)" status
assert_eq "$OUT" "ask" "fresh repo asked first from a worktree -> ask"
run_in "$TEST_ROOT/wt2-a" "$(with_fake)" setup
assert_eq "$RC" "3" "first setup from a worktree exits 3"
assert_eq "$(git -C "$TEST_ROOT/wt2-main" config --get warden.graphify)" "manual" "first setup from a worktree records manual"
run_in "$TEST_ROOT/wt2-main" "$(with_fake)" status
assert_eq "$OUT" "build" "main checkout after a worktree yes -> build"
run_in "$TEST_ROOT/wt2-main" "$(with_fake)" setup
assert_eq "$RC" "0" "setup in the main checkout then installs hooks"
assert_true "hook lands in the shared .git/hooks" test -x "$TEST_ROOT/wt2-main/.git/hooks/post-commit"
assert_eq "$(git -C "$TEST_ROOT/wt2-main" config --get warden.graphify)" "enabled" "main checkout setup upgrades the record to enabled"

echo "Test: build after hooks were removed"
rm -f "$TEST_ROOT/wt-main/.git/hooks/post-commit"
run_in "$TEST_ROOT/wt-main" "$(with_fake)" status
assert_eq "$OUT" "build" "set-up repo whose hook was deleted -> build, not ask"
run_in "$TEST_ROOT/wt-main" "$(without_cli)" status
assert_eq "$OUT" "no-cli" "no-cli wins over build"

echo "Test: core.hooksPath set after a yes does not loop on build"
make_repo "$TEST_ROOT/late-husky" 20
run_in "$TEST_ROOT/late-husky" "$(with_fake)" setup
mkdir -p "$TEST_ROOT/late-husky/.husky/_"
git -C "$TEST_ROOT/late-husky" config core.hooksPath .husky/_
run_in "$TEST_ROOT/late-husky" "$(with_fake)" status
assert_eq "$OUT" "build" "hooks shadowed by a new core.hooksPath -> build"
run_in "$TEST_ROOT/late-husky" "$(with_fake)" setup
assert_eq "$RC" "3" "setup after the hooksPath change exits 3"
assert_eq "$(git -C "$TEST_ROOT/late-husky" config --get warden.graphify)" "manual" "main checkout without hooks records manual, even after enabled"
run_in "$TEST_ROOT/late-husky" "$(with_fake)" status
assert_eq "$OUT" "ready" "status after that setup -> ready, so build does not repeat"

echo "Test: core.hooksPath points at a directory that does not exist"
make_repo "$TEST_ROOT/hp-missing" 20
git -C "$TEST_ROOT/hp-missing" config core.hooksPath .husky/_
run_in "$TEST_ROOT/hp-missing" "$(with_fake)" setup
assert_eq "$RC" "3" "missing core.hooksPath directory: setup exits 3, not 1"
assert_false "missing core.hooksPath directory: no .husky/ is created" test -e "$TEST_ROOT/hp-missing/.husky"
run_in "$TEST_ROOT/hp-missing" "$(with_fake)" status
assert_eq "$OUT" "ready" "missing core.hooksPath directory: status -> ready"
git -C "$TEST_ROOT/hp-missing" worktree add -q "$TEST_ROOT/hp-missing-wt" -b feature-b
run_in "$TEST_ROOT/hp-missing-wt" "$(with_fake)" setup
assert_eq "$RC" "3" "worktree of that repo: setup exits 3, not 1"
assert_eq "$ERR" "" "worktree of that repo: setup prints no error"

echo "Test: a fresh clone does not inherit the decision"
git clone -q "$TEST_ROOT/s3" "$TEST_ROOT/clone" 2>/dev/null
run_in "$TEST_ROOT/clone" "$(with_fake)" status
assert_eq "$OUT" "ask" "fresh clone of a set-up repo -> ask (local config is not cloned)"
make_repo "$TEST_ROOT/dec-src" 20
git -C "$TEST_ROOT/dec-src" config warden.graphify declined
git clone -q "$TEST_ROOT/dec-src" "$TEST_ROOT/dec-clone" 2>/dev/null
run_in "$TEST_ROOT/dec-clone" "$(with_fake)" status
assert_eq "$OUT" "ask" "fresh clone of a declined repo -> ask"

echo "Test: failed automatic setup keeps build and changes nothing"
make_repo "$TEST_ROOT/auto-fail" 20
git -C "$TEST_ROOT/auto-fail" config warden.graphify enabled
run_in "$TEST_ROOT/auto-fail" "$(with_fake)" status
assert_eq "$OUT" "build" "enabled record without a graph -> build"
FAKE_GRAPHIFY_FAIL=update run_in "$TEST_ROOT/auto-fail" "$(with_fake)" setup
assert_eq "$RC" "1" "automatic setup that fails exits 1"
assert_eq "$(git -C "$TEST_ROOT/auto-fail" status --porcelain)" "" "failed automatic setup leaves the work tree clean"
run_in "$TEST_ROOT/auto-fail" "$(with_fake)" status
assert_eq "$OUT" "build" "status stays build (never ask) after a failed automatic setup"

echo "Test: setup without the CLI"
make_repo "$TEST_ROOT/f4" 20
run_in "$TEST_ROOT/f4" "$(without_cli)" setup
assert_eq "$RC" "1" "setup exits 1 without graphify"
assert_true "error explains how to install" grep -q "uv tool install graphifyy" <<<"$ERR"

echo "Test: core.hooksPath configurations"
for layout in husky9 husky4 outside custom-in-repo; do
  dir="$TEST_ROOT/hp-$layout"
  make_repo "$dir" 20
  case "$layout" in
    husky9)
      mkdir -p "$dir/.husky/_"
      printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' >"$dir/.husky/_/post-commit"
      chmod 755 "$dir/.husky/_/post-commit"
      git -C "$dir" config core.hooksPath .husky/_
      ;;
    husky4)
      mkdir -p "$dir/.husky"
      printf '#!/bin/sh\nnpx lint-staged\n' >"$dir/.husky/pre-commit"
      git -C "$dir" add .husky && git -C "$dir" commit -q -m husky
      git -C "$dir" config core.hooksPath .husky
      ;;
    outside)
      mkdir -p "$TEST_ROOT/shared-hooks"
      git -C "$dir" config core.hooksPath "$TEST_ROOT/shared-hooks"
      ;;
    custom-in-repo)
      mkdir -p "$dir/.githooks"
      git -C "$dir" config core.hooksPath .githooks
      ;;
  esac
  before="$(cd "$dir" && find . -path ./.git -prune -o -type f -print | sort)"
  : >"$FAKE_LOG"
  run_in "$dir" "$(with_fake)" setup
  assert_eq "$RC" "3" "$layout: setup exits 3 (graph built, hooks not installed)"
  assert_eq "$(grep -c '^hook install$' "$FAKE_LOG")" "0" "$layout: graphify hook install is not run"
  assert_true "$layout: output says hooks were not installed" grep -q "hooks: not installed" <<<"$OUT"
  after="$(cd "$dir" && find . -path ./.git -prune -o -path ./graphify-out -prune -o -type f -print | grep -vx './.gitignore' | sort)"
  assert_eq "$after" "$before" "$layout: no hook file is written in the work tree"
  assert_false "$layout: no hook is written to .git/hooks" test -e "$dir/.git/hooks/post-commit"
  assert_eq "$(git -C "$dir" config --local --get warden.graphify)" "manual" "$layout: setup records warden.graphify=manual"
  run_in "$dir" "$(with_fake)" status
  assert_eq "$OUT" "ready" "$layout: status after manual setup -> ready"
done
assert_false "outside: shared hooks dir gets no hook" test -e "$TEST_ROOT/shared-hooks/post-commit"

make_repo "$TEST_ROOT/hp-explicit" 20
git -C "$TEST_ROOT/hp-explicit" config core.hooksPath .git/hooks
run_in "$TEST_ROOT/hp-explicit" "$(with_fake)" setup
assert_eq "$RC" "0" "core.hooksPath set to .git/hooks counts as the default directory"

make_repo "$TEST_ROOT/hp-husky-manual" 20
mkdir -p "$TEST_ROOT/hp-husky-manual/.husky/_" "$TEST_ROOT/hp-husky-manual/graphify-out"
git -C "$TEST_ROOT/hp-husky-manual" config core.hooksPath .husky/_
printf '# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$TEST_ROOT/hp-husky-manual/.husky/post-commit"
echo '{}' >"$TEST_ROOT/hp-husky-manual/graphify-out/graph.json"
run_in "$TEST_ROOT/hp-husky-manual" "$(with_fake)" status
assert_eq "$OUT" "ready" "a graphify block in .husky/post-commit under Husky 9 counts as active"

make_repo "$TEST_ROOT/hp-shadowed" 20
mkdir -p "$TEST_ROOT/hp-shadowed/graphify-out" "$TEST_ROOT/shadow-hooks"
echo '{}' >"$TEST_ROOT/hp-shadowed/graphify-out/graph.json"
printf '#!/bin/sh\n# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$TEST_ROOT/hp-shadowed/.git/hooks/post-commit"
chmod 755 "$TEST_ROOT/hp-shadowed/.git/hooks/post-commit"
git -C "$TEST_ROOT/hp-shadowed" config core.hooksPath "$TEST_ROOT/shadow-hooks"
run_in "$TEST_ROOT/hp-shadowed" "$(with_fake)" status
assert_eq "$OUT" "ask" "a hook in .git/hooks that core.hooksPath shadows is not active"

make_repo "$TEST_ROOT/hp-root-marker" 20
mkdir -p "$TEST_ROOT/hp-root-marker/.githooks" "$TEST_ROOT/hp-root-marker/graphify-out"
echo '{}' >"$TEST_ROOT/hp-root-marker/graphify-out/graph.json"
printf '#!/bin/sh\n# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$TEST_ROOT/hp-root-marker/post-commit"
git -C "$TEST_ROOT/hp-root-marker" config core.hooksPath .githooks
run_in "$TEST_ROOT/hp-root-marker" "$(with_fake)" status
assert_eq "$OUT" "ask" "a graphify block outside the hooks directory is not active"

make_repo "$TEST_ROOT/hp-outside-underscore" 20
mkdir -p "$TEST_ROOT/ext/_" "$TEST_ROOT/hp-outside-underscore/graphify-out"
echo '{}' >"$TEST_ROOT/hp-outside-underscore/graphify-out/graph.json"
printf '# graphify-hook-start\ntrue\n# graphify-hook-end\n' >"$TEST_ROOT/ext/post-commit"
git -C "$TEST_ROOT/hp-outside-underscore" config core.hooksPath "$TEST_ROOT/ext/_"
run_in "$TEST_ROOT/hp-outside-underscore" "$(with_fake)" status
assert_eq "$OUT" "ask" "a directory named _ outside the repo is not treated as Husky"

echo "Test: one-time install notice"
rm -rf "$XDG_CACHE_HOME"
marker="$XDG_CACHE_HOME/warden/graphify-install-mentioned"
run_in "$TEST_ROOT/s1" "$(with_fake)" notice
assert_eq "$OUT" "" "notice prints nothing when status is ready"
run_in "$TEST_ROOT/r19" "$(without_cli)" notice
assert_eq "$OUT" "" "notice prints nothing when status is small"
run_in "$TEST_ROOT/dec" "$(without_cli)" notice
assert_eq "$OUT" "" "notice prints nothing when status is declined"
run_in "$TEST_ROOT/r20" "$(with_fake)" notice
assert_eq "$OUT" "" "notice prints nothing when status is ask"
assert_false "no marker after notices that were not shown" test -e "$marker"
run_in "$TEST_ROOT/r20" "$(without_cli)" notice
assert_true "notice prints the install command when status is no-cli" grep -q "uv tool install graphifyy" <<<"$OUT"
assert_true "marker exists after the notice was printed" test -f "$marker"
run_in "$TEST_ROOT/f4" "$(without_cli)" notice
assert_eq "$OUT" "" "notice prints nothing the second time, even in another repo"
rm -rf "$XDG_CACHE_HOME"
(cd "$TEST_ROOT/r20" && PATH="$(without_cli)" "$SCRIPT_UNDER_TEST" notice >&-) 2>/dev/null
assert_false "no marker when the notice could not be written" test -e "$marker"

# ---- Fail cleanly where the script cannot run (REQ-3 to REQ-5) ----

echo "Test: git does not run"
STUB_GIT_BIN="$TEST_ROOT/stub-git-bin"
mkdir -p "$STUB_GIT_BIN"
printf '#!/bin/sh\nexit 1\n' >"$STUB_GIT_BIN/git"
chmod +x "$STUB_GIT_BIN/git"
make_repo "$TEST_ROOT/nogit" 20
before="$(snapshot_state "$TEST_ROOT/nogit")"
for cmd in status setup decline notice; do
  run_in "$TEST_ROOT/nogit" "$STUB_GIT_BIN:$(with_fake)" "$cmd"
  assert_eq "$RC" "4" "git blocked: $cmd exits 4"
  assert_eq "$ERR" "$BLOCK_GIT" "git blocked: $cmd prints the git blocked message"
  if [[ "$cmd" == status ]]; then
    assert_eq "$OUT" "unavailable" "git blocked: status prints unavailable"
  else
    assert_eq "$OUT" "" "git blocked: $cmd prints nothing on stdout"
  fi
done
assert_unchanged "$TEST_ROOT/nogit" "$before" "git blocked: state is unchanged"

echo "Test: a plain folder with a working git"
mkdir -p "$TEST_ROOT/plain"
for cmd in status setup decline notice; do
  run_in "$TEST_ROOT/plain" "$(with_fake)" "$cmd"
  assert_eq "$RC" "2" "plain folder: $cmd exits 2"
  assert_eq "$ERR" "graphify-setup: not inside a git work tree" "plain folder: $cmd says not inside a git work tree"
  assert_eq "$OUT" "" "plain folder: $cmd prints nothing on stdout"
done

echo "Test: graphify does not run during setup"
make_repo "$TEST_ROOT/gblock" 20
printf '*.png binary\n' >"$TEST_ROOT/gblock/.gitattributes"
before="$(snapshot_state "$TEST_ROOT/gblock")"
FAKE_GRAPHIFY_FAIL=version run_in "$TEST_ROOT/gblock" "$(with_fake)" setup
assert_eq "$RC" "4" "graphify blocked: setup exits 4"
assert_eq "$ERR" "$BLOCK_GRAPHIFY" "graphify blocked: setup prints the graphify blocked message"
assert_unchanged "$TEST_ROOT/gblock" "$before" "graphify blocked: state is unchanged"

echo "Test: .git/config is not writable"
make_repo "$TEST_ROOT/cblock" 20
printf 'node_modules/\n' >"$TEST_ROOT/cblock/.gitignore"
git -C "$TEST_ROOT/cblock" config warden.graphify manual
before="$(snapshot_state "$TEST_ROOT/cblock")"
block_config "$TEST_ROOT/cblock"
run_in "$TEST_ROOT/cblock" "$(with_fake)" setup
assert_eq "$RC" "4" "config blocked: setup exits 4"
assert_eq "$ERR" "$BLOCK_CONFIG" "config blocked: setup prints the config blocked message"
unblock_config "$TEST_ROOT/cblock"
assert_unchanged "$TEST_ROOT/cblock" "$before" "config blocked: setup leaves the state unchanged"
block_config "$TEST_ROOT/cblock"
run_in "$TEST_ROOT/cblock" "$(with_fake)" decline
assert_eq "$RC" "4" "config blocked: decline exits 4"
assert_eq "$ERR" "$BLOCK_CONFIG" "config blocked: decline prints the config blocked message"
unblock_config "$TEST_ROOT/cblock"
assert_unchanged "$TEST_ROOT/cblock" "$before" "config blocked: decline leaves the state unchanged"

echo "Test: graph build fails after creating graphify-out/"
make_repo "$TEST_ROOT/bfail" 20
printf 'node_modules/\n' >"$TEST_ROOT/bfail/.gitignore"
git -C "$TEST_ROOT/bfail" config warden.graphify manual
before="$(snapshot_state "$TEST_ROOT/bfail")"
FAKE_GRAPHIFY_FAIL=update run_in "$TEST_ROOT/bfail" "$(with_fake)" setup
assert_eq "$RC" "1" "build failure: setup exits 1"
assert_true "build failure: PR #2 message" grep -q "graph build failed. Nothing else was changed." <<<"$ERR"
assert_unchanged "$TEST_ROOT/bfail" "$before" "build failure: state is unchanged, warden.graphify reset"

echo "Test: .gitignore is not writable after the first write"
make_repo "$TEST_ROOT/ifail" 20
printf 'node_modules' >"$TEST_ROOT/ifail/.gitignore"
mkdir -p "$TEST_ROOT/ifail/graphify-out" && echo '{"old":1}' >"$TEST_ROOT/ifail/graphify-out/graph.json"
chmod a-w "$TEST_ROOT/ifail/.gitignore"
before="$(snapshot_state "$TEST_ROOT/ifail")"
run_in "$TEST_ROOT/ifail" "$(with_fake)" setup
assert_eq "$RC" "1" "gitignore failure: setup exits 1"
assert_true "gitignore failure: says it was rolled back" grep -qF "graphify-setup: .gitignore could not be updated. Setup was rolled back; nothing was changed." <<<"$ERR"
assert_unchanged "$TEST_ROOT/ifail" "$before" "gitignore failure: state is unchanged, warden.graphify unset"
assert_eq "$(cat "$TEST_ROOT/ifail/.gitignore")" "node_modules" "gitignore failure: .gitignore content is byte for byte the same"
chmod u+w "$TEST_ROOT/ifail/.gitignore"

echo "Test: final config write fails after the hooks are installed"
make_repo "$TEST_ROOT/lfail" 20
FAKE_GRAPHIFY_FAIL=hook-lock run_in "$TEST_ROOT/lfail" "$(with_fake)" setup
assert_true "config lock failure: setup exits non-zero" test "$RC" -ne 0
assert_true "config lock failure: names the post-commit hook path" grep -qF "$TEST_ROOT/lfail/.git/hooks/post-commit" <<<"$ERR"
assert_true "config lock failure: names the removal command" grep -qF "graphify hook uninstall" <<<"$ERR"
assert_true "config lock failure: says the value was not recorded" grep -qF "warden.graphify" <<<"$ERR"
assert_true "config lock failure: the hook stays installed (known limit)" grep -qF "graphify-hook-start" "$TEST_ROOT/lfail/.git/hooks/post-commit"
rm -f "$TEST_ROOT/lfail/.git/config.lock"

echo "Test: hook install fails"
make_repo "$TEST_ROOT/hfail" 20
printf 'node_modules/\n' >"$TEST_ROOT/hfail/.gitignore"
printf '*.png binary\n' >"$TEST_ROOT/hfail/.gitattributes"
git -C "$TEST_ROOT/hfail" config warden.graphify manual
git -C "$TEST_ROOT/hfail" config merge.graphify.driver "my own driver"
mkdir -p "$TEST_ROOT/hfail/graphify-out" && echo '{"old":1}' >"$TEST_ROOT/hfail/graphify-out/graph.json"
before="$(snapshot_state "$TEST_ROOT/hfail")"
FAKE_GRAPHIFY_FAIL=hook run_in "$TEST_ROOT/hfail" "$(with_fake)" setup
assert_eq "$RC" "1" "hook failure: setup exits 1"
assert_true "hook failure: PR #2 message" grep -q "hook install failed" <<<"$ERR"
assert_unchanged "$TEST_ROOT/hfail" "$before" "hook failure: state is unchanged, including .gitignore and warden.graphify"
make_repo "$TEST_ROOT/hfail2" 20
before="$(snapshot_state "$TEST_ROOT/hfail2")"
FAKE_GRAPHIFY_FAIL=hook run_in "$TEST_ROOT/hfail2" "$(with_fake)" setup
assert_unchanged "$TEST_ROOT/hfail2" "$before" "hook failure on a fresh repo: no .gitignore, no graphify-out/, no config"

echo "Test: notice marker folder is not writable"
rm -rf "$XDG_CACHE_HOME"
mkdir -p "$XDG_CACHE_HOME"
chmod a-w "$XDG_CACHE_HOME"
before="$(snapshot_state "$TEST_ROOT/r20")"
run_in "$TEST_ROOT/r20" "$(without_cli)" notice
assert_eq "$RC" "4" "marker blocked: notice exits 4"
assert_eq "$ERR" "graphify-setup: cannot run here: $XDG_CACHE_HOME/warden is not writable. Nothing was changed." "marker blocked: notice prints the marker blocked message"
assert_eq "$OUT" "" "marker blocked: no tip on stdout"
assert_unchanged "$TEST_ROOT/r20" "$before" "marker blocked: no marker and no new folder"
chmod u+w "$XDG_CACHE_HOME"
mkdir -p "$XDG_CACHE_HOME/warden"
chmod a-w "$XDG_CACHE_HOME/warden"
run_in "$TEST_ROOT/r20" "$(without_cli)" notice
assert_eq "$RC" "4" "marker blocked: existing unwritable folder exits 4"
assert_false "marker blocked: no marker file in the existing folder" test -e "$XDG_CACHE_HOME/warden/graphify-install-mentioned"
chmod u+w "$XDG_CACHE_HOME/warden"
rm -rf "$XDG_CACHE_HOME"

echo "Test: real graphify CLI"
if [[ -z "$REAL_GRAPHIFY" ]] || [[ "$REAL_GRAPHIFY" == "$FAKE_BIN/graphify" ]]; then
  echo "  [SKIP] graphify is not installed"
elif ! "$REAL_GRAPHIFY" --version >/dev/null 2>&1; then
  echo "  [SKIP] graphify does not run in this shell"
else
  REAL_PATH="$(dirname "$REAL_GRAPHIFY"):$SYSTEM_PATH"
  make_repo "$TEST_ROOT/real" 20
  run_in "$TEST_ROOT/real" "$REAL_PATH" status
  assert_eq "$OUT" "ask" "real CLI: fresh repo -> ask"
  run_in "$TEST_ROOT/real" "$REAL_PATH" setup
  assert_eq "$RC" "0" "real CLI: setup exits 0"
  [[ "$RC" == "0" ]] || echo "$ERR" | tail -5
  assert_true "real CLI: graph.json exists" test -f "$TEST_ROOT/real/graphify-out/graph.json"
  assert_false "real CLI: no .gitattributes is left behind" test -e "$TEST_ROOT/real/.gitattributes"
  assert_eq "$(git -C "$TEST_ROOT/real" config --get-regexp '^merge\.graphify\.' || true)" "" "real CLI: no merge.graphify.* keys are left behind"
  assert_eq "$(git -C "$TEST_ROOT/real" status --porcelain)" "?? .gitignore" "real CLI: only .gitignore is new in the work tree"
  run_in "$TEST_ROOT/real" "$REAL_PATH" status
  assert_eq "$OUT" "ready" "real CLI: status after setup -> ready"
  assert_true "real CLI: graphify hook status reports post-commit installed" \
    grep -q "post-commit: installed" <<<"$(cd "$TEST_ROOT/real" && PATH="$REAL_PATH" graphify hook status 2>/dev/null)"
  run_in "$TEST_ROOT/real" "$REAL_PATH" setup
  assert_eq "$(count_lines "$TEST_ROOT/real/.gitignore" "graphify-out/")" "1" "real CLI: second setup adds no duplicate .gitignore line"
  assert_eq "$(grep -c 'graphify-hook-start' "$TEST_ROOT/real/.git/hooks/post-commit")" "1" "real CLI: second setup adds no duplicate hook block"

  make_repo "$TEST_ROOT/real-husky" 20
  mkdir -p "$TEST_ROOT/real-husky/.husky/_"
  git -C "$TEST_ROOT/real-husky" config core.hooksPath .husky/_
  run_in "$TEST_ROOT/real-husky" "$REAL_PATH" setup
  assert_eq "$RC" "3" "real CLI: Husky 9 repo setup exits 3"
  assert_false "real CLI: Husky 9 repo gets no .husky/post-commit" test -e "$TEST_ROOT/real-husky/.husky/post-commit"

  make_repo "$TEST_ROOT/real-partial" 20
  printf '#!/bin/sh\necho user-hook\n' >"$TEST_ROOT/real-partial/.git/hooks/post-commit"
  chmod 644 "$TEST_ROOT/real-partial/.git/hooks/post-commit"
  run_in "$TEST_ROOT/real-partial" "$REAL_PATH" setup
  assert_eq "$RC" "1" "real CLI: setup fails when post-commit is not executable"
  assert_eq "$(git -C "$TEST_ROOT/real-partial" status --porcelain)" "" "real CLI: work tree is unchanged after the failure"
  assert_false "real CLI: post-checkout is rolled back" test -e "$TEST_ROOT/real-partial/.git/hooks/post-checkout"
  assert_false "real CLI: graphify block is rolled back from post-commit" grep -qF "graphify-hook-start" "$TEST_ROOT/real-partial/.git/hooks/post-commit"
  assert_true "real CLI: user hook survives the rollback" grep -qx "echo user-hook" "$TEST_ROOT/real-partial/.git/hooks/post-commit"

  make_repo "$TEST_ROOT/real-wt" 20
  run_in "$TEST_ROOT/real-wt" "$REAL_PATH" setup
  git -C "$TEST_ROOT/real-wt" worktree add -q "$TEST_ROOT/real-wt-a" -b feature-a
  run_in "$TEST_ROOT/real-wt-a" "$REAL_PATH" status
  assert_eq "$OUT" "build" "real CLI: worktree of a set-up repo -> build"
  run_in "$TEST_ROOT/real-wt-a" "$REAL_PATH" setup
  assert_eq "$RC" "3" "real CLI: worktree setup exits 3"
  run_in "$TEST_ROOT/real-wt-a" "$REAL_PATH" status
  assert_eq "$OUT" "ready" "real CLI: worktree with its own graph -> ready"
fi

echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "graphify-setup tests failed: $FAILURES"
  exit 1
fi
echo "All graphify-setup tests passed"
