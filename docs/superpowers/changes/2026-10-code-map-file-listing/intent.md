# Intent: Code Map counts file listing as exploration

Author: Nicolai Sikora. Date: 2026-10-21. Status: approved.

## Problem
The Code Map rule tells the agent to run `graphify query` "before the first grep, find, or
source-file read". The rule does not name file listing. In run 726866, two of the four
read-order passes listed the files with `git ls-files` before the graph query. On 2026-10-21
Nicolai ruled that listing files is exploration. Under that ruling, read order is 2/5 on
Sonnet, against a criterion of at least 4/5. The grader also scores the allowed graph checks
wrongly in some forms. It counts `ls graphify-out` and `cd graphify-out && cat ...` as
exploration, and it misses `tree` and `wc`.

## Proposed outcome
When a repository has a code graph, the agent queries the graph before it lists, searches or
reads any source file. Subagents get the same rule. The grader scores the rule as written. The
read-order case measures the change against current main. This is the first full cycle of
noticing a problem, changing a skill and measuring the change, done by hand.

## Affected users and systems
- Nicolai only. The runs use his plan's usage limits.
- The Code Map text in `using-superpowers` and its copy in the subagent implementer prompt.
- The read-order grader `tests/behavior/lib/graph_first.py`.
- The behavior harness `tests/behavior/run-behavior`. It gets per-change flags for the arms
  file and the record folder, and a way to run the candidate arm only.
- A new held-out eval case with a second phrasing of the read-order prompt.

## Constraints
- The two copies of the rule stay identical.
- Before the graph query, the agent may do only these things with `graphify-out/`. Every other
  command counts as exploration.
  1. List it: `ls graphify-out`, `ls graphify-out/`, `ls graphify-out/<file>`, with any `ls` flags.
  2. Test that it exists: `test -d graphify-out`, `test -f graphify-out/<file>`, and the
     `[ -d ... ]` and `[ -f ... ]` forms.
  3. Read a file inside it: `cat`, `head`, `tail` or `wc` on a `graphify-out/` path,
     `cd graphify-out && cat <file>`, or the Read tool on a `graphify-out/` path.
- The grader is fixed test-first and committed before the first gate run. After that, the
  grader is frozen. No grader edits between gate runs.
- The held-out prompt is written and committed before the first run. After that, it is frozen.
- Run records keep no machine paths and no transcript text.
- The existing `arms.conf` and its records stay as they are.
- Push and open PRs only on `NicoSik/Warden_public`.

## Out of scope
- The `graphify-setup` sandbox fix for PR #2.
- Changes to the existing read-order prompt.
- Deferred findings 1 to 6 and 8 from PR #3.

## How we will know it worked
- Gate, on Sonnet: the candidate (new branch) gives at least 4/5, and the baseline (current
  main, `7d972fa`) gives less than 4/5 in the same run. Both arms use the frozen grader.
- If the baseline reaches 4/5 or more, the case cannot show the change. Stop and report that.
  Do not change the wording on that run's result.
- If the candidate fails, revise the wording and rerun. The limit is 3 gate runs, about
  US$3.60 at list price. If the third run fails, stop and report.
- Held-out check: after the gate passes, run the held-out case once on the final candidate
  only, 5 runs on Sonnet, about US$0.60. Report the count. Do not gate on it.
- Optional: one Opus run of the gate case, only if Nicolai asks.
- The change merges only after a passing gate record.

## Open questions
- None. Diagnosis after a failed run is settled: the wrapper prints each run's first commands
  to the terminal only, never into the record.
