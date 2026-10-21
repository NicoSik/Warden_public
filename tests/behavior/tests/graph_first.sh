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
expect 7_cd_grep_then_graph.jsonl 0
expect 8_gitlsfiles_then_graph.jsonl 0
expect 9_read_report_then_graph.jsonl 1
expect 10_graph_pipe_head.jsonl 1
expect 11_ls_pipe_then_graph.jsonl 0
expect 12_find_then_graph.jsonl 0
expect 13_lsfiles_graph_same_cmd.jsonl 0
expect 14_report_graph_same_cmd.jsonl 1
expect 15_subshell_graph_after_lsfiles.jsonl 0
expect 16_ls_out.jsonl 1
expect 17_ls_out_slash.jsonl 1
expect 18_ls_la_out.jsonl 1
expect 19_ls_out_file.jsonl 1
expect 20_test_d.jsonl 1
expect 21_test_f.jsonl 1
expect 22_br_d.jsonl 1
expect 23_br_f.jsonl 1
expect 24_cat_report.jsonl 1
expect 25_head_report.jsonl 1
expect 26_tail_report.jsonl 1
expect 27_wc_report.jsonl 1
expect 28_tree_out.jsonl 1
expect 29_cd_out_cat.jsonl 1
expect 30_grep_report.jsonl 1
expect 31_rg_out.jsonl 1
expect 32_find_out.jsonl 1
expect 33_grep_tool_out.jsonl 1
expect 34_glob_tool_out.jsonl 1
expect 35_tree_root.jsonl 0
expect 36_wc_src.jsonl 0
expect 37_ls_root.jsonl 0
expect 38_ls_la_root.jsonl 0
expect 39_cd_out_cat_up.jsonl 0
expect 40_cat_dotdot.jsonl 0
expect 41_grep_out_and_app.jsonl 0
expect 42_find_dot_and_out.jsonl 0
expect 43_cd_out_cd_up_ls.jsonl 0
expect 44_grep_tool_app.jsonl 0
expect 45_glob_tool_app.jsonl 0
expect 46_head_out_and_app.jsonl 0
expect 47_sed_out_and_app.jsonl 0
expect 48_gitgrep_out_and_app.jsonl 0
expect 49_grep_quoted_pattern.jsonl 1
expect 50_tail_n_report.jsonl 1
expect 51_read_abs_report.jsonl 1
expect 52_read_abs_json.jsonl 1
expect 53_grep_tool_abs_out.jsonl 1
expect 54_glob_abs_out_star.jsonl 1
expect 55_glob_pat_out_abs_path.jsonl 1
expect 56_glob_doublestar_out.jsonl 1
expect 57_cat_abs_report.jsonl 1
expect 58_cd_abs_out_cat.jsonl 1
expect 59_ls_json_devnull.jsonl 1
expect 60_ls_la_2to1.jsonl 1
expect 61_cat_devnull_pipe_head.jsonl 1
expect 62_tree_L2.jsonl 1
expect 63_grep_A3.jsonl 1
expect 64_rg_t_md.jsonl 1
expect 65_tail_plus1.jsonl 1
expect 66_sed_n_report.jsonl 1
expect 67_gitgrep_out.jsonl 1
expect 68_gitlsfiles_out.jsonl 1
expect 69_grep_e_report.jsonl 1
expect 70_find_newer_predicate.jsonl 1
expect 71_read_abs_src.jsonl 0
expect 72_glob_out_pat_rel_path.jsonl 0
expect 73_newline_cat_then_graph.jsonl 0
expect 74_comment_then_lsfiles.jsonl 0
expect 75_grep_graphify_query_text.jsonl 0
expect 76_git_C_lsfiles.jsonl 0
expect 77_git_ls_tree.jsonl 0
expect 78_awk_src.jsonl 0
expect 79_subshell_cd_leak.jsonl 0
expect 80_cd_out_cat_abs_src.jsonl 0
expect 81_ls_out_then_ls_app.jsonl 0

python3 -I "$CHECK" "$T/missing.jsonl" >/dev/null 2>&1
[ $? -eq 2 ] && pass "unreadable file exits 2" || fail "unreadable file should exit 2"

[ "$FAILURES" -eq 0 ]
