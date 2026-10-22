#!/usr/bin/env bash
# REQ-2. The installer registers the marketplaces and installs the monitor.
. "$(dirname "$0")/lib/harness.sh"
harness_setup

# Build the tarball the curl stub will serve. Two fake executables, one README.
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE/payload"
printf '#!/bin/sh\necho monitor\n' > "$WARDEN_STUB_STAGE/payload/claude-context-monitor"
printf '#!/bin/sh\necho statusline\n' > "$WARDEN_STUB_STAGE/payload/claude-statusline"
printf 'readme\n' > "$WARDEN_STUB_STAGE/payload/README.md"
chmod +x "$WARDEN_STUB_STAGE/payload/"claude-*
( cd "$WARDEN_STUB_STAGE/payload" \
  && tar czf "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_darwin_arm64.tar.gz" . )
cp "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_darwin_arm64.tar.gz" \
   "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_linux_amd64.tar.gz"

WARDEN_OS=darwin WARDEN_ARCH=arm64 "$REPO_DIR/install.sh" --skip-plugin-hook >/dev/null 2>&1
log=$(cat "$WARDEN_STUB_LOG")

# REQ-2.1
assert_contains "$log" "claude plugin marketplace add $REPO_DIR/plugins/superpowers"
# REQ-2.2
assert_contains "$log" "claude plugin marketplace add $REPO_DIR/plugins/warden"
assert_contains "$log" "claude plugin marketplace add cathrynlavery/diagram-design"
# REQ-2.4
assert_file "$HOME/bin/claude-context-monitor"
assert_file "$HOME/bin/claude-statusline"
if [ -x "$HOME/bin/claude-statusline" ]; then
  pass "claude-statusline is executable"
else
  fail "claude-statusline is not executable"
fi

# REQ-2.5. An unsupported architecture stops the installer.
harness_teardown
harness_setup
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE"
out=$(WARDEN_OS=plan9 WARDEN_ARCH=sparc "$REPO_DIR/install.sh" --skip-plugin-hook 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  pass "an unsupported platform exits non-zero"
else
  fail "an unsupported platform exited 0"
fi
assert_contains "$out" "no release asset for plan9/sparc"
assert_absent "$HOME/bin/claude-statusline"

# REQ-2.6. A missing prerequisite stops the installer before it archives.
harness_teardown
harness_setup
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE"
mkdir -p "$HARNESS_TMP/emptybin"
out=$(PATH="$HARNESS_TMP/emptybin:/usr/bin:/bin" "$REPO_DIR/install.sh" --skip-plugin-hook 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  pass "a missing prerequisite exits non-zero"
else
  fail "a missing prerequisite exited 0"
fi
assert_contains "$out" "missing prerequisite: claude"
assert_absent "$HOME/.warden-backups"

# REQ-2.3. A checksum mismatch stops the installer before anything is installed.
harness_teardown
harness_setup
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE/payload"
printf '#!/bin/sh\necho monitor\n' > "$WARDEN_STUB_STAGE/payload/claude-context-monitor"
printf '#!/bin/sh\necho statusline\n' > "$WARDEN_STUB_STAGE/payload/claude-statusline"
chmod +x "$WARDEN_STUB_STAGE/payload/"claude-*
( cd "$WARDEN_STUB_STAGE/payload" \
  && tar czf "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_darwin_arm64.tar.gz" . )
cp "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_darwin_arm64.tar.gz" \
   "$WARDEN_STUB_STAGE/claude-context-monitor_1.1.0_linux_amd64.tar.gz"
out=$(WARDEN_OS=darwin WARDEN_ARCH=arm64 WARDEN_STUB_BAD_SUM=1 "$REPO_DIR/install.sh" --skip-plugin-hook 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  pass "a checksum mismatch exits non-zero"
else
  fail "a checksum mismatch exited 0"
fi
assert_contains "$out" "checksum mismatch"
assert_absent "$HOME/bin/claude-context-monitor"
assert_absent "$HOME/bin/claude-statusline"

# I-2 regression. --dry-run without --skip-deps fetches nothing and writes
# nothing. INSTALL.md Step 1 runs the dry run before the Step 2 consent gate,
# so anything it writes is written without the person's agreement (REQ-5.2).
harness_teardown
harness_setup
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE"

out=$(WARDEN_OS=darwin WARDEN_ARCH=arm64 \
  "$REPO_DIR/install.sh" --dry-run --skip-plugin-hook 2>&1)

# REQ-3.5. It still says what it would do.
assert_contains "$out" "would fetch: the latest stigsb/claude-context-monitor release for darwin/arm64"
assert_contains "$out" "would install: $HOME/bin/claude-context-monitor"
assert_contains "$out" "would install: $HOME/bin/claude-statusline"
assert_contains "$out" "would register the vendored superpowers marketplace"
assert_contains "$out" "would register the vendored warden marketplace"

assert_absent "$HOME/bin"
assert_absent "$HOME/.warden-backups"

log=$(cat "$WARDEN_STUB_LOG")
if [ -z "$log" ]; then
  pass "the dry run made no curl and no claude call"
else
  fail "the dry run called out: $log"
fi

# I-3 regression. A download that fails stops the installer. It used to
# return 1 into a call with no check: the installer printed its summary,
# exited 0, and left settings.json wiring a PostToolUse hook at a binary
# that was never installed.
harness_teardown
harness_setup
export WARDEN_STUB_STAGE="$HARNESS_TMP/stage"
mkdir -p "$WARDEN_STUB_STAGE" "$HARNESS_TMP/failbin"
printf '#!/bin/sh\nexit 6\n' > "$HARNESS_TMP/failbin/curl"
chmod +x "$HARNESS_TMP/failbin/curl"

out=$(PATH="$HARNESS_TMP/failbin:$PATH" WARDEN_OS=darwin WARDEN_ARCH=arm64 \
  "$REPO_DIR/install.sh" --skip-plugin-hook 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
  pass "a failed download exits non-zero"
else
  fail "a failed download exited 0"
fi
assert_contains "$out" "could not read the release list"
case "$out" in
  *"summary:"*) fail "the installer printed its summary after a failed download" ;;
  *) pass "the installer printed no summary after a failed download" ;;
esac
assert_absent "$HOME/bin"

# F32 regression. settings.json must not enable a plugin from a marketplace
# install_plugins never registers. The two names are the marketplace ids the
# `claude plugin marketplace add` calls above produce: superpowers-dev is
# asserted against plugins/superpowers/.claude-plugin/marketplace.json in
# tests/vendored_license.sh, warden is asserted against
# plugins/warden/.claude-plugin/marketplace.json just below, and
# diagram-design is the repository's own name.
warden_mk=$(jq -r '.name' "$REPO_DIR/plugins/warden/.claude-plugin/marketplace.json")
if [ "$warden_mk" = "warden" ]; then
  pass "plugins/warden/.claude-plugin/marketplace.json names the marketplace warden"
else
  fail "plugins/warden marketplace.json names '$warden_mk', not warden"
fi
for mk in $(jq -r '.enabledPlugins | keys[]' "$REPO_DIR/settings.json" \
            | sed 's/.*@//' | sort -u); do
  case "$mk" in
    superpowers-dev|diagram-design|"$warden_mk")
      pass "enabledPlugins names the registered marketplace $mk" ;;
    *)
      fail "settings.json enables a plugin from $mk, which install.sh does not register" ;;
  esac
done

# REQ-4.2. The allowlist above only rejects unknown keys; this requires the
# warden key itself.
require_warden_enabled() {
  jq -e '.enabledPlugins["warden@warden"] == true' "$1" >/dev/null 2>&1
}
if require_warden_enabled "$REPO_DIR/settings.json"; then
  pass "settings.json enables warden@warden"
else
  fail "settings.json does not enable warden@warden"
fi

harness_exit
