#!/usr/bin/env bash
# Offline test for lib/graph_first.py. Never starts a real claude.
set -uo pipefail
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../../lib/harness.sh"
CHECK="$HERE/../lib/graph_first.py"
T="$HERE/traces"

expect() {
  local file="$1" want="$2" out
  out=$(python3 -I "$CHECK" "$T/$file" 2>&1)
  if [ "$(printf '%s\n' "$out" | head -n1)" = "graph_first=$want" ]; then
    pass "$file -> graph_first=$want"
  else
    fail "$file wanted graph_first=$want, got: $out"
  fi
}

expect 1_graph_then_read.jsonl 1
expect 2_read_then_graph.jsonl 0
expect 3_only_grep.jsonl 0
expect 4_report_then_graph.jsonl 1
expect 5_no_tools.jsonl 0
expect 6_noise.jsonl 1

python3 -I "$CHECK" "$T/missing.jsonl" >/dev/null 2>&1
[ $? -eq 2 ] && pass "unreadable file exits 2" || fail "unreadable file should exit 2"

[ "$FAILURES" -eq 0 ]
