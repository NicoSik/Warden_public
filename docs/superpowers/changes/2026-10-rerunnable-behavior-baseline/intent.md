# Intent: Rerunnable behavior baseline

Author: Nicolai Sikora. Date: 2026-10-20. Status: approved.

## Problem
Warden's skill changes have no evidence that can be rerun. The Graphify trigger
results behind PRs #1 and #2 (planning 5/5, quick question 0/5, non-coding 0/5)
came from one-off prompts in a scratchpad that no longer exist as tests. The fork's
own rule requires eval evidence for every behavior change, so neither PR meets it.
No later change can be compared with a baseline, because no baseline exists.

## Proposed outcome
One command reruns the Graphify trigger scenarios against a chosen set of skills
and prints a pass/fail table per scenario. Each agent runs as its own `claude -p`
process, which also removes the subagent confound of the earlier tests. Each
scenario is graded from what the agents did, not from what they reported:

- Helper calls are recorded by a logging shim. The copy of the skills under test
  holds a small wrapper at the path the skill calls
  (`using-superpowers/scripts/graphify-setup`). The wrapper appends the repo name
  and the arguments to a per-run log, then runs the real script.
- Repo state is read from each scratch repo's local git config and work tree.

A run against current main is recorded as the baseline. PRs #1 and #2 get that
record as their evidence. Later changes run the same command on a candidate
branch and compare it with the baseline.

## Affected users and systems
- Nicolai only. The command spends his model allowance.
- The Warden repo (NicoSik fork): a new folder under `tests/` and its runner.
- The vendored Superpowers plugin: read only. Its skills are what the runner tests.
- Graphify CLI: required. If it is missing, the run stops before any agent starts.
- The macOS Keychain and Claude login: read through the environment only, never
  copied (see Constraints).

## Constraints
- No quorum yet, so local harness only.
- Runs happen in scratch directories. A run never touches a real project, the
  real `~/.claude`, or Warden's own git state.
- Auth, checked with `claude auth status` on 2026-10-20 (Claude Code 2.1.305):
  - A scratch `HOME` or `CLAUDE_CONFIG_DIR` is logged out, because the macOS
    Keychain entry is keyed to the config directory.
  - Those runs created only `.claude.json` and its backups, and no credential files.
  - `--bare` reads only `ANTHROPIC_API_KEY` or `apiKeyHelper`, never OAuth.
  - So an isolated run authenticates with `CLAUDE_CODE_OAUTH_TOKEN` (from
    `claude setup-token`), passed in the environment only. No credential is ever
    written into a scratch directory.
- A run prints its cost before it starts (agents to start, model, expected token
  range) and needs Nicolai to start it. It is never run by CI or by a hook.
- Every run record pins the Claude Code CLI version, the model ID actually used,
  the commit SHA of the skills under test, and the Graphify version.
- The skill location is an input, so the Graphify skill can move to a Warden-level
  plugin without breaking the baseline.
- Grading reads side effects only. The agents' own reports are kept for reading,
  but never decide pass or fail.
- The model is Nicolai's account default (no `--model` flag). A flag selects a
  cheaper model. The default is 5 reps per scenario.

## Out of scope
- Lesson capture, triage, the ledger, and the eval gate.
- Moving Graphify into its own plugin. That is a separate change, and this
  harness then measures it.
- The zsh glob hook. It gets written directly, outside this loop.
- Statistics beyond pass counts. With 5 reps only large effects count, and the
  output says so.

## How we will know it worked
- Running the command against main gives planning >= 4/5, quick question <= 1/5
  and non-coding <= 1/5.
- If `claude -p` does not reproduce the earlier subagent numbers, the difference is
  recorded as a finding. The harness is not tuned to match them.
- A planted regression (the Setup check removed from the skill) turns the planning
  scenario below 4/5.
- PRs #1 and #2 link a baseline run record.

## Open questions
- Does Claude Code pass `CLAUDE_CODE_OAUTH_TOKEN` to the agent's Bash commands? If
  it does, an agent could print it into a transcript. This is checked before the
  first real run, and the run is blocked until it is safe.
- Where does Nicolai keep the long-lived token, and does the runner read it from
  the Keychain or from his shell? `claude setup-token` creates a one-year token
  and saves it nowhere.
