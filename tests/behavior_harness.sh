#!/usr/bin/env bash
# Run every tests/behavior/tests/*.sh, or the one named in $1. Exit non-zero on any failure.
set -uo pipefail
DIR=$(cd -P "$(dirname "$0")/behavior/tests" && pwd)
failed=0
if [ $# -gt 0 ]; then
  set -- "$DIR/${1%.sh}.sh"
else
  set -- "$DIR"/*.sh
fi
for t in "$@"; do
  [ -f "$t" ] || { printf 'missing %s\n' "$(basename "$t")"; failed=$((failed + 1)); continue; }
  printf '%s\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done
[ "$failed" -eq 0 ]
