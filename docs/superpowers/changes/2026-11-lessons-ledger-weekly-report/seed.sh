#!/usr/bin/env bash
# Writes the four seed entries of the lessons ledger. Safe to run twice: a slug
# that already has an entry is skipped. Stops at the first mark that fails.
WL="${WARDEN_LESSON:-warden-lesson}"

existing="$($WL mark --list)" || exit $?

seed() {
  local slug="$1"; shift
  if printf '%s\n' "$existing" | awk -v s="$slug" '$1 == s { f = 1 } END { exit !f }'; then
    echo "skip $slug (already has an entry)"
    return 0
  fi
  $WL mark "$slug" "$@" || exit $?
}

seed zsh-equals-word verified --match '^\(eval\):N: \S+ not found$' --pr 11 --fixed-on 2026-11-10 \
  --note 'zsh =word expands to a command path. The hook denies an unquoted =word since #11.'
seed zsh-include-glob verified --match '^\(eval\):N: no matches found: \S*--include=' --pr 11 --fixed-on 2026-11-10 \
  --note '0 occurrences in the 9 sessions from 2026-11-10 to 2026-11-17, the week after #11.'
seed setup-check-miss fixed --nudge --pr 13 --fixed-on 2026-11-25 \
  --note 'Live check pending. Matches a nudge with no setup-call, so it cannot see a miss where no nudge fired.'
seed hedges-output-line ignored --match '^Hedges<path> \(may, might, could\)' \
  --note 'A script output line, not a failure.'

$WL mark --list
