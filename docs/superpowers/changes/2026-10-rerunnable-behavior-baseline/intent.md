# Intent: Rerunnable behavior baseline

Author: Nicolai Sikora. Date: 2026-10-20. Status: approved.

## Problem
Warden's skill changes have no evidence that can be rerun. The Graphify trigger
results behind PRs #1 and #2 (planning 5/5, quick question 0/5, non-coding 0/5)
came from one-off prompts in a scratchpad that no longer exist as tests. The fork's
own rule requires eval evidence for every behavior change, so neither PR meets it.
No later change can be compared with a baseline, because no baseline exists.

## Proposed outcome
One command reruns the Graphify trigger scenarios against two commits of the
Superpowers plugin and prints a pass count per scenario and arm. It is built on
`claude plugin eval`, which runs each case as an isolated `claude -p` child (own
temporary home, working directory and config, only the plugin loaded, the shell
always sandboxed) on Nicolai's own login, repeats runs, and grades them.

Each scenario compares a baseline arm with a candidate arm, each a commit of
the skills under test:

| Scenario | Baseline arm | Candidate arm |
|---|---|---|
| Setup check: planning, quick question, non-coding | `c91be4c` (main, no Setup check) | `5a972be` (PR #2 head) |
| Code Map read order | `8199034` (before PR #1) | `c91be4c` (PR #1 merged) |

The baseline arm is the negative control. Grading reads what the agent did, not
what it said:

- Setup check: a `tool_used` grader counts Bash calls to `graphify-setup ... status`.
- Read order: a small check over the kept trace asks whether a `graphify query`,
  `explain` or `path` call came before the first file read or search.

The runs measure whether the agent **tries** the right step, not what happens
next. Inside the eval sandbox on macOS, `git` (Apple's `xcrun` launcher), the
home-installed Graphify binary, and writes to `.git/config` are all blocked
(probed 2026-10-21). So `graphify-setup` and `graphify query` fail inside a
run. PRs #1 and #2 get the run record as their evidence, and the record states
this limit.

## Affected users and systems
- Nicolai only. Runs use his plan's usage limits.
- The Warden repo (NicoSik fork): an eval suite and a thin wrapper under `tests/`.
- The vendored Superpowers plugin: read only; copied per arm into scratch.
- Graphify CLI: needed by the read-order fixture setup, which runs outside the
  sandbox. If it is missing, the run stops before any agent starts.

## Constraints
- No quorum yet. `claude plugin eval` plus a thin wrapper.
- A run never touches a real project, the real `~/.claude`, or Warden's git state.
- The wrapper refuses to start when `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`
  is set, because plugin eval passes both through and they outrank the login.
- Reports stay local: every run passes `--no-publish`.
- Before starting, the wrapper prints the agent count, the model, and the
  estimated cost, labelled "list-price estimate; not billed on a subscription
  login, uses your plan's usage limits", and waits for `y`. The docs define
  `costUsd` as an estimate at list price.
- Every run record pins the Claude Code version, the model, each arm's commit
  SHA, the Graphify version, and the fixture's tree hash.
- The skill location is an input, so the Graphify skill can later move to a
  Warden-level plugin without breaking the baseline.
- The model is the account default unless a flag names a cheaper one. 5 runs
  per case by default.

## Out of scope
- Lesson capture, triage, the ledger, and the eval gate.
- Moving Graphify into its own plugin. That is a separate change, and this
  harness then measures it.
- The zsh glob hook. It gets written directly, outside this loop.
- Statistics beyond pass counts. With 5 reps only large effects count, and the
  output says so.

## How we will know it worked
- Setup check, candidate arm: planning >= 4/5, quick question <= 1/5,
  non-coding <= 1/5. The baseline arm is recorded next to it.
- Code Map read order, candidate arm: graph queried first in >= 4/5. The
  baseline arm is recorded next to it.
- If `claude -p` does not reproduce the earlier subagent numbers, the difference is
  recorded as a finding. The harness is not tuned to match them.
- PRs #1 and #2 link a baseline run record.

## Open questions
- None. The sandbox limit is recorded above; fixing `graphify-setup` for
  sandboxed sessions is a separate change.
