# Spec: version-change-suite

Intent: `intent.md`. Date: 2026-11-27. Status: approved.

## Summary

This change makes the Monday weekly job record the Claude Code version and the default model
ID, and notify Nicolai when either one changes in a way that matters. A new command,
`warden-lesson suite`, runs every behavior case on main behind the existing cost prompt and
compares the result with the suite record of the previous version. The weekly job never runs
an eval, so no eval uses the usage limits without Nicolai's y.

Size: 9 requirements from 29 intent items (9 outcome paragraphs, 5 constraints, 9 resolved
questions, 6 rulings from the 2026-11-27 design review) and the four design sections approved
on 2026-11-27.

## Terms

- **The lesson script** is `plugins/warden/scripts/warden-lesson`.
- **The ledger module** is `plugins/warden/scripts/warden_ledger.py`. It holds the `weekly`,
  `schedule` and status code.
- **The wrapper** is `tests/behavior/run-behavior`.
- **The recorder** is `tests/behavior/lib/record.py`.
- **The suite folder** is `<inbox>/suite/`, `~/.claude/lessons/suite/` by default.
- **The weekly folder** is `<inbox>/weekly/`.
- **The suite config** is `tests/behavior/evals/suite.conf`.
- **A suite case** is a directory under `tests/behavior/evals/` other than `_fixture`.
- **The checkout** is the repository that holds the lesson script that runs.
- **An arm** is one commit with one model setting. Two arms on one commit with different
  models are two arms.
- **The main arm** is the arm that runs the checkout's HEAD with the account default model.
- **The A/B arm** is the arm that runs the same commit with the `--ab-model` ID pinned.
- **A suite record** is one Markdown record and its summary in the suite folder.
- **A summary** is the JSON file of a suite record.
- **The CLI version** is the first `X.Y.Z` number in the `claude --version` output.
- **The CLI minor** is the `X.Y` part of the CLI version.
- **The full pins** are the CLI version plus the model ID of a summary.
- **The minor pins** are the CLI minor plus the model ID.
- **A case result** is `PASS`, `FAIL` or `ERRORED` for one case and one arm.
- **The combined view** of a group of summaries holds, for each suite case, the newest
  non-`ERRORED` case result of the main arm in that group. A case with only `ERRORED` results
  stays `ERRORED`.
- **A covered group** is a group of summaries with the same minor pins whose combined view has
  a non-`ERRORED` case result for every case in the suite config.
- **Covered** means that the summaries with the current minor pins form a covered group.
- **The newest covered group** is the covered group whose newest summary is the newest.
- **The log window** is the time from the `ts` of the last weekly run to now. Without a last
  run, it is the last 7 days.
- **A main-session line** is a transcript line of type `assistant` that is in a file outside any
  `subagents/` folder, has no `isSidechain: true`, and has a model other than `<synthetic>`.
- **The current pins** are the CLI version and the model ID that one weekly run reads.

## Requirements

### Behavior

**REQ-1** The suite command MUST run every suite case on the checkout's HEAD, one main arm per
case, behind the wrapper's cost prompt.
  - **REQ-1.1** The suite command MUST exit 2 with `suite runs only on main (current: <branch>)`
    when the checkout is on a branch other than `main`.
  - **REQ-1.2** The suite command MUST exit 2 with `suite needs a clean checkout: <path>` when a
    staged, unstaged or untracked change exists under `plugins/` or `tests/behavior/`.
  - **REQ-1.3** The suite command MUST NOT refuse a change outside `plugins/` and
    `tests/behavior/`.
  - **REQ-1.4** The suite command MUST make both checks before the preflight and before the
    cost prompt.
  - **REQ-1.5** When local `main` is behind `fork/main` as of the last fetch, the suite command
    MUST print `warning: main is <N> commits behind fork/main (last fetch)` before the cost
    prompt.
  - **REQ-1.6** The suite command MUST NOT fetch.
  - **REQ-1.7** The suite command MUST exit 2 with `no suite criterion for <case>` when a suite
    case has no line in the suite config.
  - **REQ-1.8** The suite command MUST exit 2 with `no eval directory for <case>` when a suite
    config line names no suite case.
  - **REQ-1.9** The suite command MUST grade each case by the rule and the count of its suite
    config line, the same way the wrapper grades a candidate-only row today.
  - **REQ-1.10** The suite command MUST run `read-order` and `read-order-heldout` with the
    setup status stub, and every other case with the real setup script, as the wrapper does
    today.
  - **REQ-1.11** `--case <name>` MUST limit the run to that suite case.
  - **REQ-1.12** `--runs N` MUST set the runs per arm, with 5 as the default.
  - **REQ-1.13** `--ab-model <ID>` MUST add one A/B arm per case.
  - **REQ-1.14** The cost estimate MUST count the A/B arms before the prompt.
  - **REQ-1.15** Without `--ab-model`, the main arm MUST use the account default model.
  - **REQ-1.16** The suite command MUST exit with the exit code of the wrapper.
  *Proof: T1 to T11 in `tests/behavior/tests/runner.sh`.*
  *Source: outcome paragraph 6. Resolved questions on cases and criteria. Rulings on the clean
  checkout, the behind warning and the setup status stub. Design section 1.*

**REQ-2** The wrapper MUST run and grade one arm per pair of commit and model.
  - **REQ-2.1** An arms row MAY carry an optional sixth column with a model ID for its
    candidate arm.
  - **REQ-2.2** The wrapper MUST pass `--model <ID>` from the sixth column to the eval of that
    arm.
  - **REQ-2.3** Two arms on one commit with different models MUST produce two separate result
    sets and two separate rows in the record.
  - **REQ-2.4** A five-column row MUST run and grade exactly as it does today.
  - **REQ-2.5** The recorder MUST grade the setup cases of records `726866` and `cbb2f3` to the
    same results as today.
  - **REQ-2.6** The Markdown record MUST name the model of each arm when two arms on one commit
    differ in model.
  *Proof: T12 to T14 in `runner.sh`. The golden tests in
  `tests/behavior/tests/record_grading.sh`.*
  *Source: outcome paragraph 8. Ruling on test-first per-arm model support and golden records.
  Constraint "existing run-behavior records and their grading stay valid".*

**REQ-3** After a suite record, the suite command MUST print a comparison of the combined view
of the new full pins with the combined view of the newest earlier full pins that differ.
  - **REQ-3.1** The comparison MUST name both groups: the summary IDs, the short SHAs, the CLI
    versions and the models.
  - **REQ-3.2** The comparison MUST print `plugin files: changed between <old7> and <new7>` or
    `plugin files: unchanged`, by a git diff of `plugins/` between the two SHAs.
  - **REQ-3.3** When the old SHA is not in the checkout, the comparison MUST print
    `plugin files: unknown (<old7> not found)`.
  - **REQ-3.4** The comparison MUST print one row per case with the old and new count/runs and
    case result, and the summary ID that each case result came from.
  - **REQ-3.5** The comparison MUST mark a row `FLIPPED` only when one case result is `PASS`
    and the other is `FAIL`.
  - **REQ-3.6** A count change without a flip MUST NOT mark a row.
  - **REQ-3.7** When either case result is `ERRORED`, the row MUST print
    `not comparable (<N> errored)` and `rerun: warden-lesson suite --case <case>`.
  - **REQ-3.8** A row with an `ERRORED` case result MUST NOT print `FLIPPED`.
  - **REQ-3.9** A case in only one group MUST print `new case` or `not in old record`, without a
    mark.
  - **REQ-3.10** When no earlier group has different full pins, the comparison MUST print
    `no earlier suite record with different pins`, plus the ID of the newest summary with the
    same full pins when one exists.
  - **REQ-3.11** With `--ab-model`, the comparison MUST print a second block that compares the
    A/B arm with the main arm of the same run by the rules of REQ-3.5 to REQ-3.8.
  - **REQ-3.12** The comparison with the old group MUST use the main arm only.
  - **REQ-3.13** The comparison MUST skip a summary that does not parse and print
    `skipped unreadable summary: <file>` on stderr.
  *Proof: T15 to T23 in `tests/behavior/tests/suite_compare.sh`.*
  *Source: outcome paragraph 7. Rulings on the two guards, `ERRORED` and the combined view.
  Design section 2.*

**REQ-4** Each weekly run MUST read the current pins without a model call.
  - **REQ-4.1** The weekly run MUST run the stored `claude` path with `--version` and a timeout
    of 10 seconds.
  - **REQ-4.2** When that call fails, the weekly run MUST record the error in `last-run` and
    skip only the CLI check.
  - **REQ-4.3** The weekly run MUST take the model ID that occurs most often among the
    main-session lines of the log window under `~/.claude/projects/`.
  - **REQ-4.4** On a tie, the weekly run MUST take the model of the newest tied line.
  - **REQ-4.5** When the log window has no main-session line, the weekly run MUST take the
    `model` key of `~/.claude/settings.json`.
  - **REQ-4.6** When that key is absent or is not a full model ID, the weekly run MUST record the
    model as `unknown`.
  - **REQ-4.7** The weekly run MUST NOT copy transcript text into any file. It records only the
    model ID and the line count. (Ruling F1, 2026-11-27.)
  *Proof: T24 to T30 in `tests/warden_ledger.sh`.*
  *Source: outcome paragraphs 1 and 2. Resolved questions on the model source and the log
  window. Constraint "the weekly job uses no usage limits". REQ-4.7: ruling F1.*

**REQ-5** The weekly run MUST notify when the current pins are not covered.
  - **REQ-5.1** The weekly run MUST notify `no complete suite record yet` when no covered group
    exists.
  - **REQ-5.2** The notification MUST repeat on each weekly run until the current pins are
    covered.
  - **REQ-5.3** A partial or single-case summary MUST stop the notification only when the
    combined view makes the current pins covered.
  - **REQ-5.4** A CLI difference in the patch number only MUST NOT notify.
  - **REQ-5.5** An `unknown` model MUST NOT notify.
  - **REQ-5.6** The version text MUST name the old value from the newest covered group, the
    new value and the command `warden-lesson suite`. (Ruling F2, 2026-11-27.)
  - **REQ-5.7** The weekly run MUST send one notification that holds the ledger text and the
    version text when both apply.
  - **REQ-5.8** The ledger notifications MUST fire under the same conditions as today.
  - **REQ-5.9** A week with no ledger hits and covered pins MUST send no notification.
  - **REQ-5.10** The weekly report file MUST state whether the current pins differ from the
    pins of the last weekly run, including a patch-only difference.
  - **REQ-5.11** The weekly run MUST NOT start an eval.
  - **REQ-5.12** When the weekly run skips the CLI check, it MUST judge coverage by the model
    ID alone.
  *Proof: T31 to T40, T51 and T52 in `tests/warden_ledger.sh`. A `git grep` shows no call from the ledger
  module to the wrapper.*
  *Source: outcome paragraphs 4 and 5. Resolved question on the notification rule. Ruling on
  coverage.
  Constraints "no eval starts without the prompt" and "existing ledger notifications keep
  working". Design section 3.*

### Data

**REQ-6** In suite mode, the recorder MUST write a summary beside the Markdown record.
  - **REQ-6.1** The summary MUST hold `id`, `date` in UTC, the full `sha`, the CLI version,
    the raw `claude --version` line, the model of the main arm, the graphify version, the
    fixture hash and the runs per arm.
  - **REQ-6.2** The summary MUST hold one entry per case and arm with `case`, `arm` (`main` or
    `ab`), `model`, `count`, `errored`, `runs`, `rule`, `threshold` and `result`.
  - **REQ-6.3** The recorder MUST set `result` to `ERRORED` when a case and arm has one or more
    errored runs.
  - **REQ-6.4** The Markdown record MUST keep its current format.
  - **REQ-6.5** The recorder MUST write the summary after the Markdown record, through a temp
    file and a rename.
  - **REQ-6.6** The recorder MUST NOT write a summary for a run that writes no record.
  - **REQ-6.7** The recorder MUST NOT write a summary for a two-arm run.
  *Proof: T41 to T44 in `record_grading.sh`.*
  *Source: design section 2 and approach A1. Ruling on `ERRORED`.*

**REQ-7** Suite records MUST stay in the suite folder, outside the repository.
  - **REQ-7.1** The suite command MUST write every suite record to the suite folder.
  - **REQ-7.2** A command MUST NOT delete or change a file in the suite folder after its write.
  - **REQ-7.3** `last-run` MUST hold `cli_version`, `model`, `model_source` (`logs`,
    `settings` or `unknown`) and `model_lines`.
  *Proof: T9 in `runner.sh`. T45 in `tests/warden_ledger.sh`. `tests/no_machine_content.sh`
  shows no home path in the repository.*
  *Source: resolved question on the suite folder. Constraint "nothing with a home path is
  committed". Design section 3.*

### Interface

**REQ-8** The lesson script MUST offer the suite command, and status and schedule MUST report
the version check.
  - **REQ-8.1** `warden-lesson suite [--case NAME] [--runs N] [--ab-model ID]` MUST run the
    wrapper of the checkout in suite mode with those flags.
  - **REQ-8.2** `schedule install` MUST store the path that `shutil.which("claude")` returns,
    without resolving symlinks, in the job's environment.
  - **REQ-8.3** When `claude` is not found, `schedule install` MUST succeed and print
    `claude not found; the version check is off`.
  - **REQ-8.4** `status` MUST print `suite: last run <date> on <CLI version>, <model>. Now
    <CLI version>, <model> (<source>)` when a summary exists.
  - **REQ-8.5** `status` MUST print `suite: never run` when no summary exists.
  - **REQ-8.6** `status` MUST print `version check: claude not found at schedule install` when
    the job has no stored `claude` path.
  - **REQ-8.7** The existing `status` lines MUST stay unchanged.
  *Proof: T46 to T50 in `tests/warden_ledger.sh`.*
  *Source: outcome paragraphs 3, 4 and 6. Resolved question on the `claude` path. Design
  sections 1 and 3.*

### Operations

**REQ-9** All tests for this change MUST run offline.
  - **REQ-9.1** A test MUST NOT start a real `claude`.
  - **REQ-9.2** `bash tests/run.sh` MUST pass.
  - **REQ-9.3** `bash tests/behavior_harness.sh runner` MUST pass.
  - **REQ-9.4** The per-arm model tests MUST fail on the branch before the wrapper change.
  *Proof: the output of both commands in the PR. The commit order on the branch shows the
  failing test before the wrapper change.*
  *Source: "How we will know it worked". Ruling on test-first per-arm model support. Design
  section 4.*

## Test list

`tests/behavior/tests/runner.sh` (stub `claude`, stub `graphify`, temp git repository):
- T1: the suite refuses a branch other than `main`.
- T2: the suite refuses a change under `plugins/`.
- T3: the suite refuses an untracked file under `tests/behavior/`.
- T4: the suite accepts a change outside both paths.
- T5: the behind warning prints before the prompt, and the suite makes no fetch.
- T6: the suite refuses a suite case without a suite config line.
- T7: the suite refuses a suite config line without a directory.
- T8: the setup status stub runs for `read-order` and `read-order-heldout`, the real script
  runs for the setup cases, and the record pins `stubbed (ready)`.
- T9: the record and the summary land in the record folder, and the suite deletes nothing there.
- T10: `--case` runs one case.
- T11: `--ab-model` doubles the agent count in the estimate.
- T12: a six-column row passes `--model` for that arm.
- T13: two arms on one commit with different models give two rows.
- T14: a five-column row runs as today.

`tests/behavior/tests/suite_compare.sh` (hand-written summaries):
- T15: a pass/fail flip prints `FLIPPED`.
- T16: a count change without a flip prints no mark.
- T17: an `ERRORED` case prints `not comparable` and the rerun hint, never `FLIPPED`.
- T18: the combined view takes a `--case` rerun over the errored result of the full run.
- T19: the plugin-files line reads `changed` and `unchanged` for the two cases.
- T20: a missing old SHA prints `unknown`.
- T21: the first summary prints `no earlier suite record with different pins`.
- T22: the comparison skips an unreadable summary and names it.
- T23: the A/B block compares the A/B arm with the main arm.

`tests/warden_ledger.sh` (synthetic transcripts, stub `claude`, stub `osascript`):
- T24: subagent files do not count.
- T25: sidechain lines do not count.
- T26: one `/model` switch in a week of sessions does not change the model.
- T27: a tie goes to the model of the newest tied line.
- T28: an empty log window falls back to `settings.json` and records `settings`.
- T29: an alias in `settings.json` gives `unknown`.
- T30: no transcript text appears in the weekly folder.
- T31: an empty suite folder notifies `no complete suite record yet`.
- T32: a model change notifies.
- T33: the notification repeats on the next weekly run while the pins are not covered.
- T34: a CLI minor change notifies.
- T35: a patch-only change does not notify.
- T36: a single-case summary alone does not stop the notification.
- T37: a full run plus a rerun of its errored cases stops the notification.
- T38: a failed `claude --version` records the error and the model check still runs.
- T39: the ledger and version text arrive in one notification.
- T40: a quiet week with covered pins sends no notification.
- T45: `last-run` holds the four new fields.
- T46: `schedule install` stores the unresolved symlink path.
- T47: `schedule install` without `claude` succeeds and prints the warning.
- T48: `status` prints the suite line.
- T49: `status` prints `suite: never run`.
- T50: `status` prints the `claude not found` warning.
- T51: with a failed CLI check, a covered model sends no version notification.
- T52: a newer summary with an `ERRORED` case does not become the old value. The text names
  the newest covered group.

`tests/behavior/tests/record_grading.sh`:
- T41: a suite run writes a summary with the fields of REQ-6.1 and REQ-6.2.
- T42: an errored run gives `ERRORED` in the summary and `FAIL` in the Markdown record.
- T43: a two-arm run writes no summary.
- T44: a run without a record writes no summary.

## Non-goals

- Running evals on a schedule, in CI or from the weekly job. Evals need Nicolai's y.
- Rerunning an old Claude Code version. The old CLI cannot be installed beside the new one.
- Notifying on a patch-only CLI change. Claude Code updates almost weekly.
- Changing the case criteria or the graders. The suite config copies today's criteria.
- Pruning or committing suite records. They are a local history.
- Reading the CLI version from the transcripts. `claude --version` is the source the records
  already pin.

## Constraints applied

Rules and area guides:
- `CLAUDE.md`: test first for features, reuse the existing helpers, one check with a pass or
  fail result. REQ-2 reuses the wrapper's candidate-only row. REQ-4 reuses the weekly run.
- `tests/behavior/README.md`: the wrapper never checks out a ref and never touches the git state
  of the repository. REQ-1.5 reads `fork/main` without a fetch. The `[y/N]` prompt stays.
- `rules/instruction-files.md` applies only to instruction files. This change edits none.
- `plugins/superpowers/AGENTS.md` applies to `plugins/superpowers`. This change edits nothing
  there.

Policy skills: this is a tooling repository with no product domain, and it has no policy
skill. One item touches personal data: the weekly run reads Nicolai's own session transcripts.
REQ-4.7 limits what the weekly run keeps (ruling F1).

## Flagged concerns

Nicolai ruled on both concerns on 2026-11-27.

- **F1: what the weekly run keeps from the transcripts.** The intent says the model comes from
  the session logs. It says nothing about what the job stores from them. Ruling: keep REQ-4.7.
  The weekly run keeps only the model ID and the line count.
- **F2: the source of the old value in the notification.** The newest summary and the newest
  covered group differ when a suite ran on new pins and left a case `ERRORED`. Ruling: the old
  value comes from the newest covered group. REQ-5.6 states it.

## Open questions carried from intent

- The suite record format: answered by REQ-6.
- How the comparison tells whether the plugin files changed: answered by REQ-3.2 and REQ-3.3.
- How `--ab-model` results appear in the comparison: answered by REQ-3.10 and REQ-3.11.
- Outcome paragraph 9, the first suite run after the merge, is Nicolai's action. It has no
  requirement. The success check in the intent reads its result.
- The intent resolved all other questions. Their answers are in REQ-1, REQ-4, REQ-5, REQ-7 and
  REQ-8.

## Design notes

- The suite command is a front door. The suite logic lives in the wrapper and in a new
  comparison script beside the recorder, so all eval code stays in `tests/behavior`.
- The weekly run and the comparison read only summaries, never the Markdown records.
- The checkout's lesson script runs the checkout's wrapper. The live plugins read from
  `~/Warden_public`, so `warden-lesson suite` runs the wrapper on `main` there.
