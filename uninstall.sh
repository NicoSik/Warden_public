#!/usr/bin/env bash
# Remove the Warden links and put back what they displaced.
#
#   ./uninstall.sh              remove the links, restore the backups
#   ./uninstall.sh --dry-run    print every action, write nothing
set -uo pipefail

SELF_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SELF_DIR/lib/warden-common.sh"

REPO="$SELF_DIR"
CFG=$(warden_config_dir)
WARDEN_DRY_RUN=0

FROM_ARCHIVE=""
WANT_ARCHIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) WARDEN_DRY_RUN=1 ;;
    --from-archive)
      WANT_ARCHIVE=1
      case "${2:-}" in
        ""|--*) ;;
        *) FROM_ARCHIVE="$2"; shift ;;
      esac ;;
    -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warden_die "unknown option: $1" ;;
  esac
  shift
done
export WARDEN_DRY_RUN

restore_from_archive() {
  local archive="$1" parent base ex entry skip new_archive=""
  [ -f "$archive" ] || warden_die "no such archive: $archive"
  # Read the archive before deleting anything it is meant to put back. A path
  # that is not a readable archive must stop the restore here, while the
  # configuration directory is still whole.
  tar tzf "$archive" >/dev/null 2>&1 || warden_die "not a readable archive: $archive"
  # REQ-4.5.2
  warden_say "archiving the current state first"
  if [ "$WARDEN_DRY_RUN" = "1" ]; then
    warden_say "would archive: $CFG -> $(warden_backup_dir)/claude-<stamp>.tar.gz"
  else
    new_archive=$(warden_archive_config "$CFG" "$(warden_backup_dir)") \
      || warden_die "could not archive $CFG before restoring"
    warden_say "archive: $new_archive"
  fi

  # REQ-4.5.3. Remove only what the archive can put back.
  for entry in "$CFG"/* "$CFG"/.[!.]*; do
    [ -e "$entry" ] || continue
    base=$(basename "$entry")
    skip=0
    for ex in $WARDEN_EXCLUDES; do
      [ "$base" = "$ex" ] && skip=1
    done
    [ "$skip" = "1" ] && continue
    warden_run "remove: $entry" rm -rf "$entry" || warden_die "could not remove $entry"
  done

  parent=$(dirname "$CFG")
  warden_run "restore: $archive -> $CFG" tar xzf "$archive" -C "$parent" \
    || warden_die "the restore failed. Your previous state is in ${new_archive:-$(warden_backup_dir)}"
  warden_say "restored from $archive"
}

if [ "$WANT_ARCHIVE" = "1" ]; then
  if [ -z "$FROM_ARCHIVE" ]; then
    warden_say "archives under $(warden_backup_dir):"
    ls -1t "$(warden_backup_dir)"/claude-*.tar.gz 2>/dev/null | head -10 \
      || warden_say "  none"
    exit 0
  fi
  restore_from_archive "$FROM_ARCHIVE"
  exit 0
fi

# unlink_one <link_path>
# Removes the link only when it points into this repository. REQ-4.1, REQ-4.3.
unlink_one() {
  local link="$1" target newest
  [ -L "$link" ] || { warden_say "skip: $link is not a Warden link"; return 0; }
  target=$(readlink "$link")
  case "$target" in
    "$REPO"/*) ;;
    *) warden_say "skip: $link points at $target"; return 0 ;;
  esac
  warden_run "unlink: $link" rm -f "$link" || return 1
  # REQ-4.2. The newest backup wins, and the names sort by time.
  newest=$(ls -1 "$link".warden-backup-* 2>/dev/null | sort | tail -1)
  if [ -n "$newest" ]; then
    warden_run "restore: $newest -> $link" mv "$newest" "$link" \
      || warden_die "could not restore $newest to $link"
  fi
}

for name in $WARDEN_SURFACES; do
  unlink_one "$CFG/$name"
done
for name in $WARDEN_DOC_SURFACES; do
  unlink_one "$CFG/docs/$name"
done
unlink_one "$HOME/.local/bin/warden-handoff"

# REQ-4.4. The person decides about the plugins and the binaries.
cat <<'EOF'

The plugins and the monitor binaries are still installed. To remove them:

  claude plugin marketplace remove superpowers-dev
  claude plugin marketplace remove diagram-design
  claude plugin marketplace remove warden
  rm -f $HOME/bin/claude-context-monitor $HOME/bin/claude-statusline
EOF
