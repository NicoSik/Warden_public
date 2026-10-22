#!/usr/bin/env bash
# REQ-6. The repository carries nothing that names one machine or one organization.
. "$(dirname "$0")/lib/harness.sh"

cd "$REPO_DIR" || exit 1

check_pattern() {
  local label="$1" pattern="$2" hits
  # The only exclusion is this file, which must hold the patterns it hunts.
  # Nothing else is exempt: the change records under docs/superpowers/changes/
  # used to be, and three machine paths lived there unseen by the test and by
  # the pre-commit hook.
  hits=$(git grep -I -l -E "$pattern" -- . \
    | grep -v '^tests/no_machine_content.sh$' || true)
  if [ -n "$hits" ]; then
    fail "$label found in: $(printf '%s' "$hits" | tr '\n' ' ')"
  else
    pass "no $label"
  fi
}

check_pattern "absolute home path" '/(Users|home)/[A-Za-z0-9._-]+'
# REQ-6.2 forbids a third-party agent hook block, not one vendor's. The
# pattern matches the shape such a block takes rather than a name: a hook
# command invoking a path under an agent-hooks directory, or an encoded
# PowerShell payload. Either half alone is enough to flag an injected block,
# and neither half names a product.
check_pattern "agent hook block" '/agent-hooks/|EncodedCommand'

# REQ-6.3 forbids a private or organization-internal marketplace, not one
# name. A denylist pattern would have to name the marketplace to catch it,
# which puts the private name back into the repository -- the thing the
# owner ordered removed. An allowlist over settings.json does the same job
# without naming anything private: it fails on any marketplace or plugin
# this repository did not itself register.
check_settings_allowlist() {
  local settings="${1:-$REPO_DIR/settings.json}" key ok=1

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    case "$key" in
      diagram-design) ;;
      *)
        fail "extraKnownMarketplaces registers $key, which install.sh does not"
        ok=0
        ;;
    esac
  done < <(jq -r '.extraKnownMarketplaces // {} | keys[]' "$settings")

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    case "$key" in
      diagram-design@diagram-design|superpowers@superpowers-dev|warden@warden) ;;
      *)
        fail "enabledPlugins enables $key, which is not one of the three allowed plugins"
        ok=0
        ;;
    esac
  done < <(jq -r '.enabledPlugins // {} | keys[]' "$settings")

  [ "$ok" -eq 1 ] && pass "settings.json declares only the registered marketplaces and plugins"
}
check_settings_allowlist

# The allowlist must still reject a key it does not know. Run it against a
# temp copy of settings.json with an extra x@y key; the failure is captured,
# not counted.
allowlist_tmp=$(mktemp "${TMPDIR:-/tmp}/warden-settings.XXXXXX")
jq '.enabledPlugins["x@y"] = true' "$REPO_DIR/settings.json" > "$allowlist_tmp"
rejected=$( fail() { printf 'FAIL %s\n' "$*"; }; pass() { :; }
            check_settings_allowlist "$allowlist_tmp" )
rm -f "$allowlist_tmp"
case "$rejected" in
  *"enables x@y"*) pass "the allowlist rejects an extra x@y plugin key" ;;
  *) fail "the allowlist accepted an extra x@y plugin key" ;;
esac

forbidden_files() {
  local f
  for f in RESTORE-shepherd.txt skills/synced; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      fail "$f is tracked"
    else
      pass "$f is not tracked"
    fi
  done
}
forbidden_files

# REQ-6.6. assets/warden.png is the only allowed binary.
bins=""
while IFS= read -r f; do
  mime=$(file --mime-type -b -- "$f" 2>/dev/null)
  case "$mime" in
    application/x-mach-binary|application/x-executable|application/x-sharedlib)
      bins="$bins $f"
      ;;
  esac
done < <(git ls-files)
if [ -n "$bins" ]; then
  fail "compiled binary tracked:$bins"
else
  pass "no compiled binary tracked"
fi

harness_exit
