# Intent: Version change detection and the suite command

Author: Nicolai Sikora. Date: 2026-11-27. Status: approved.

## Problem
Claude Code updates almost weekly, and the default model changes now and then. Either one can
change how the plugins behave, but nothing tells Nicolai when it happens. Every behavior record
so far compares two commits under one version, so no record shows what a version change did to
main. The read-order drop in records 004564 and 9caece needed a manual comparison of the pins
to rule out a version change. A version change turned out not to be the cause.

## Proposed outcome
The Monday weekly job records `claude --version` and the default model ID.

The model ID comes from the session logs under ~/.claude/projects since the last weekly run.
The first run uses the last 7 days.
- Subagent and sidechain lines are skipped, because the subagents run on Sonnet.
- The most common model among the main-session lines wins, so one manual /model switch does
  not read as an update.
- If no session ran in that window, the job falls back to the `model` key in
  ~/.claude/settings.json. The weekly record says which source it used.

`warden-lesson schedule install` finds `claude` with `shutil.which` and stores that path
without resolving symlinks. If `claude` is missing, `warden-lesson status` says so.

The notification says that a meaningful change happened and names the suite command to run.
A meaningful change is a new model ID or a new CLI minor version (2.1 → 2.2). The notification
repeats every Monday until a suite record carries the current pins. A CLI patch-only change
gives no notification. `warden-lesson status` shows which version the last suite ran on.

The weekly job never runs evals. Evals use Nicolai's usage limits and need his y.

`warden-lesson suite` runs every eval directory except `_fixture` on main HEAD, one arm per
case, behind the existing cost prompt. Each case's criterion comes from a committed
`suite.conf`. The suite refuses a case that has no criterion there. Each case uses the same
criterion on its one arm as it does in a two-arm run.

The suite writes a suite record to ~/.claude/lessons/suite/. Suite records are never pruned
and never committed. The suite prints a comparison with the newest earlier suite record that
has different pins:
- The comparison says whether the plugin files changed between the two records, and names
  both commits.
- A case is flagged only when its pass/fail result under its own criterion flips.
- Raw counts are shown, but a count change alone does not flag.
- The first suite run has nothing to compare and only records.

An optional `--ab-model <id>` flag also runs main with that model pinned in the same suite,
for a direct old-model/new-model comparison. It doubles the agent count.

After the merge, Nicolai runs one suite to create the first suite record.

## Affected users and systems
- Nicolai, as the only reader of the notification and the suite output.
- `plugins/warden/scripts/warden-lesson` and `warden_ledger.py` (weekly job, status, schedule).
- `tests/behavior/run-behavior` and its record format.
- `tests/warden_lessons.sh`, `tests/warden_ledger.sh` and the behavior harness tests.
- The weekly files under ~/.claude/lessons/weekly.
- The new suite records under ~/.claude/lessons/suite/.

## Constraints
- No eval starts without the `[y/N]` prompt and Nicolai's y.
- The weekly job uses no usage limits.
- Existing ledger notifications (recurring fixes, unacknowledged signatures) keep working.
- Existing run-behavior records and their grading stay valid.
- Nothing with a home path is committed.

## Out of scope
- Running evals automatically, on a schedule or in CI.
- Installing or rerunning an old Claude Code version.
- Notifying on CLI patch-only changes.
- Changing the case criteria or the graders.
- Pruning or committing suite records.

## How we will know it worked
- Offline tests check that:
  - a model change notifies, and repeats until a suite record has the new pins,
  - a CLI minor change notifies, a patch-only change does not,
  - subagent and sidechain lines do not count toward the model ID,
  - one /model switch in a week of sessions does not change the model ID,
  - a week without sessions falls back to settings.json and records the source,
  - the suite refuses a case with no criterion in `suite.conf`,
  - the comparison flags a pass/fail flip and does not flag a count-only change,
  - the comparison reports whether the plugin files changed between the two commits.
- After the merge: one suite record exists in ~/.claude/lessons/suite/.
- At the next model or CLI minor change: the Monday notification fires, and the suite
  comparison runs against that first record.

## Resolved questions
- The suite compares with the newest earlier suite record that has different pins.
- A flag needs a pass/fail flip. Count changes alone do not flag.
- The model ID comes from the session logs, most common main-session model, with the
  settings.json key as the fallback.
- Notifications repeat weekly until a suite record carries the current pins, and only for a
  model change or a CLI minor change.
- "All cases" means every eval directory except `_fixture`, with criteria in `suite.conf`.
- Suite records live in ~/.claude/lessons/suite/, never pruned and not committed.
- `schedule install` stores the `shutil.which` path of `claude`, unresolved.
- The log window is since the last weekly run. The first run uses 7 days.
- A one-arm case uses the same criterion as in a two-arm run.

## Open questions
- None from the interview. The spec still has to fix the suite record format, how the
  comparison tells whether the plugin files changed, and how `--ab-model` results appear in
  the comparison.
