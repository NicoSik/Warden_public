#!/usr/bin/env bash
# Install the Warden Claude Code setup on this computer.
#
#   ./install.sh              archive, link, install dependencies
#   ./install.sh --dry-run    print every action, write nothing
#   ./install.sh --skip-deps  archive and link only
#   ./install.sh --skip-plugin-hook  skip wiring the git pre-commit hook
set -uo pipefail

SELF_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SELF_DIR/lib/warden-common.sh"

REPO="$SELF_DIR"
CFG=$(warden_config_dir)
WARDEN_DRY_RUN=0
SKIP_DEPS=0
SKIP_PLUGIN_HOOK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) WARDEN_DRY_RUN=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --skip-plugin-hook) SKIP_PLUGIN_HOOK=1 ;;
    -h|--help)
      sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) warden_die "unknown option: $1" ;;
  esac
  shift
done
export WARDEN_DRY_RUN

warden_say "repository: $REPO"
warden_say "claude config: $CFG"

check_prereqs() {
  local need missing tools
  missing=""
  # tar writes the archive and git wires the pre-commit hook, so both are
  # needed even with --skip-deps.
  tools="git tar"
  # Only the dependency step reaches the plugin CLI, the release API and the
  # checksum tool.
  if [ "$SKIP_DEPS" != "1" ]; then
    tools="$tools jq curl claude"
    command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
      || missing="$missing shasum"
  fi
  for need in $tools; do
    command -v "$need" >/dev/null 2>&1 || missing="$missing $need"
  done
  if [ -n "$missing" ]; then
    for need in $missing; do
      printf 'warden: missing prerequisite: %s\n' "$need" >&2
    done
    exit 1
  fi
}
check_prereqs

# REQ-3.6.6. No change without an archive.
if [ "$WARDEN_DRY_RUN" = "1" ]; then
  warden_say "would archive: $CFG -> $(warden_backup_dir)/claude-<stamp>.tar.gz"
else
  mkdir -p "$CFG"
  ARCHIVE=$(warden_archive_config "$CFG" "$(warden_backup_dir)") \
    || warden_die "could not archive $CFG"
  warden_say "archive: $ARCHIVE"
fi

# One linking path for both modes. warden_link routes every write through
# warden_run, so the dry run prints what the real run would do — the backup
# rename included. REQ-3.5.
for name in $WARDEN_SURFACES; do
  warden_link "$REPO/$name" "$CFG/$name" || warden_die "could not link $name"
done
for name in $WARDEN_DOC_SURFACES; do
  warden_link "$REPO/docs/$name" "$CFG/docs/$name" || warden_die "could not link docs/$name"
done
warden_link "$REPO/bin/warden-handoff" "$HOME/.local/bin/warden-handoff" \
  || warden_die "could not link warden-handoff"

install_plugins() {
  warden_run "register the vendored superpowers marketplace" \
    claude plugin marketplace add "$REPO/plugins/superpowers" \
    || warden_die "could not register the superpowers marketplace"
  warden_run "register the vendored warden marketplace" \
    claude plugin marketplace add "$REPO/plugins/warden" \
    || warden_die "could not register the warden marketplace"
  warden_run "register the diagram-design marketplace" \
    claude plugin marketplace add cathrynlavery/diagram-design \
    || warden_die "could not register the diagram-design marketplace"
}

WARDEN_MONITOR_REPO="${WARDEN_MONITOR_REPO:-stigsb/claude-context-monitor}"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

install_monitor() {
  local os arch api json asset_url sums_url tmp name bin want got found
  os="${WARDEN_OS:-$(uname -s | tr 'A-Z' 'a-z')}"
  case "${WARDEN_ARCH:-$(uname -m)}" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *)             arch="${WARDEN_ARCH:-$(uname -m)}" ;;
  esac

  # REQ-3.5. A dry run fetches nothing and creates nothing: the steps below
  # write to $TMPDIR and to $HOME/bin, and INSTALL.md runs the dry run before
  # the person has agreed to anything.
  if [ "$WARDEN_DRY_RUN" = "1" ]; then
    warden_say "would fetch: the latest $WARDEN_MONITOR_REPO release for $os/$arch"
    warden_say "would verify: that release against its checksums.txt"
    warden_say "would install: $HOME/bin/claude-context-monitor"
    warden_say "would install: $HOME/bin/claude-statusline"
    return 0
  fi

  api="https://api.github.com/repos/$WARDEN_MONITOR_REPO/releases/latest"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/warden-monitor.XXXXXX") \
    || warden_die "could not make a temporary directory for the download"
  curl -fsSL -o "$tmp/release.json" "$api" \
    || { rm -rf "$tmp"; warden_die "could not read the release list at $api"; }

  asset_url=$(jq -r --arg s "_${os}_${arch}.tar.gz" \
    '.assets[] | select(.name | endswith($s)) | .browser_download_url' \
    "$tmp/release.json" | head -1)
  if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
    rm -rf "$tmp"
    warden_die "no release asset for $os/$arch in $WARDEN_MONITOR_REPO"
  fi
  name=$(basename "$asset_url")

  sums_url=$(jq -r '.assets[] | select(.name == "checksums.txt") | .browser_download_url' \
    "$tmp/release.json" | head -1)
  [ -n "$sums_url" ] && [ "$sums_url" != "null" ] \
    || { rm -rf "$tmp"; warden_die "the release has no checksums.txt"; }

  curl -fsSL -o "$tmp/$name" "$asset_url" || { rm -rf "$tmp"; warden_die "download failed"; }
  curl -fsSL -o "$tmp/checksums.txt" "$sums_url" \
    || { rm -rf "$tmp"; warden_die "checksum download failed"; }

  want=$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1}' "$tmp/checksums.txt" | head -1)
  got=$(sha256_of "$tmp/$name")
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    rm -rf "$tmp"
    warden_die "checksum mismatch for $name"
  fi
  warden_say "checksum ok: $name"

  mkdir -p "$tmp/x" "$HOME/bin"
  tar xzf "$tmp/$name" -C "$tmp/x" || { rm -rf "$tmp"; warden_die "unpack failed"; }
  for bin in claude-context-monitor claude-statusline; do
    found=$(find "$tmp/x" -name "$bin" -type f | head -1)
    [ -n "$found" ] || { rm -rf "$tmp"; warden_die "$bin is not in the archive"; }
    warden_run "install: $HOME/bin/$bin" install -m 0755 "$found" "$HOME/bin/$bin" \
      || { rm -rf "$tmp"; warden_die "could not install $bin"; }
  done
  rm -rf "$tmp"
}

if [ "$SKIP_DEPS" = "1" ]; then
  warden_say "skipping the dependencies"
else
  install_plugins
  install_monitor || warden_die "could not install the context monitor"
fi

install_git_hook() {
  [ -e "$REPO/.git" ] || { warden_say "skip: the repository is not a git checkout"; return 0; }
  local current
  current=$(git -C "$REPO" config --get core.hooksPath 2>/dev/null)
  if [ "$current" = ".githooks" ]; then
    warden_say "keep: core.hooksPath is .githooks"
    return 0
  fi
  if [ -n "$current" ]; then
    warden_say "skip: core.hooksPath is already set to $current"
    warden_say "to wire the scrub hook by hand: git -C \"$REPO\" config core.hooksPath .githooks"
    return 0
  fi
  warden_run "set core.hooksPath to .githooks" \
    git -C "$REPO" config core.hooksPath .githooks
}
[ "${SKIP_PLUGIN_HOOK:-0}" = "1" ] || install_git_hook

if [ "$WARDEN_DRY_RUN" = "1" ]; then
  warden_say "summary: would link $WARDEN_MADE, keep $WARDEN_KEPT, back up $WARDEN_BACKED_UP"
else
  warden_say "summary: $WARDEN_MADE linked, $WARDEN_KEPT kept, $WARDEN_BACKED_UP backed up"
fi
