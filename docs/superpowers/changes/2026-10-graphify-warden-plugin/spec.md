# Spec: graphify-warden-plugin

Intent: `intent.md`. Date: 2026-10-22. Status: draft.

## Summary

This change moves the Code Map rule out of the vendored Superpowers plugin into a new plugin
named `warden`. The `warden` plugin gives the rule to the main session and to every subagent
through hooks. The behavior harness learns to load both plugins as one, to gate a baseline arm,
and to keep the traces it grades.

Size: 9 requirements from 15 intent items.

## Terms

- **The rule text** is the `## Code Map` section of `skills/using-superpowers/SKILL.md` at commit
  `7ac111f`, from its heading to the line before the next heading. It ends with the line "Put
  these four steps in every subagent prompt that explores code."
- **The `warden` plugin** is the new plugin under `plugins/warden/`.
- **The Superpowers plugin** is the vendored copy under `plugins/superpowers/`.
- **The wrapper** is `tests/behavior/run-behavior`.
- **The grader** is `tests/behavior/lib/record.py`.
- **An arm** is one commit that the wrapper evaluates for one case.
- **The trace cache** is the folder that the wrapper writes raw results and traces into. The
  default is `$HOME/.cache/warden-behavior`. `WARDEN_BEHAVIOR_RAW_DIR` overrides it.
- **A run folder** is one folder in the trace cache whose name is a six-character lowercase
  hexadecimal run ID.

## Requirements

### Behavior

**REQ-1** The `warden` plugin MUST give the rule text to the main session when a session starts.

- **REQ-1.1** The `warden` plugin MUST fire on the same session-start sources as the Superpowers
  hook: `startup`, `clear` and `compact`.
- **REQ-1.2** The injected context MUST equal the rule text byte for byte.
- **REQ-1.3** The `warden` plugin MUST inject the rule text whether `graphify-out/graph.json`
  exists or not. The rule text states its own condition.

*Proof: `tests/warden_hooks.sh` runs the session-start hook script and asserts that
`hookSpecificOutput.hookEventName` is `SessionStart` and that `additionalContext` equals the rule
text file. The manual smoke check in REQ-9 shows the hook firing in a real session.*
*Source: decision A1. Constraint "The Code Map text the agent sees does not change in wording".*

**REQ-2** The `warden` plugin MUST give the rule text to every subagent when the subagent starts.

- **REQ-2.1** The subagent-start hook MUST match every agent type. It MUST NOT name a matcher.
- **REQ-2.2** The injected context MUST equal the rule text byte for byte. It is the same file
  that REQ-1 injects.

*Proof: `tests/warden_hooks.sh` runs the subagent-start hook script and asserts that
`hookEventName` is `SubagentStart` and that `additionalContext` equals the rule text file. It also
asserts that `plugins/warden/hooks/hooks.json` registers `SessionStart` and `SubagentStart`. The
2026-10-22 probe (session `0d58bfb4`, Claude Code 2.1.308) showed that a plugin-registered
`SubagentStart` hook reaches a `general-purpose` subagent.*
*Source: intent measure "An offline check shows that the Code Map rule still reaches subagents".
Open question "How the subagent rule reaches subagents", answered by decision A1.*

**REQ-3** The Superpowers plugin MUST NOT carry Graphify content.

- **REQ-3.1** `skills/using-superpowers/SKILL.md` MUST NOT contain the `## Code Map` section.
- **REQ-3.2** `skills/subagent-driven-development/implementer-prompt.md` MUST NOT contain the
  `## Code Map` section.
- **REQ-3.3** The change MUST NOT change any other line of the Superpowers plugin.

*Proof: `grep -ri graphify plugins/superpowers` prints nothing. `git diff 7ac111f --
plugins/superpowers` shows only the deletion of the two sections.*
*Source: intent problem and outcome "The vendored Superpowers plugin has no Graphify content".*

### Interface

**REQ-4** The installer MUST register the `warden` plugin next to the Superpowers plugin.

- **REQ-4.1** The installer MUST run `claude plugin marketplace add` on the absolute path of
  `plugins/warden`, as it does for `plugins/superpowers`.
- **REQ-4.2** The shipped `settings.json` MUST enable the `warden` plugin in `enabledPlugins`.
- **REQ-4.3** `tests/no_machine_content.sh` MUST accept the `warden` key and MUST still reject
  every other unlisted key.
- **REQ-4.4** The uninstaller MUST print the command that deletes the `warden` marketplace, next
  to the two commands it prints today.
- **REQ-4.5** `README.md` MUST list `plugins/warden/` in its file table and in its marketplace
  description.

*Proof: `tests/run.sh` passes, including `install_links.sh`, `install_snapshot.sh`,
`no_machine_content.sh` and `readme_sections.sh`. A reviewer reads the `install.sh` and
`uninstall.sh` diffs.*
*Source: intent outcome "`install.sh` registers next to Superpowers". Affected systems
`install.sh`, `uninstall.sh`, `README.md`.*

**REQ-5** The wrapper MUST evaluate an arm that contains `plugins/warden` as one plugin that holds
both plugins.

- **REQ-5.1** For such an arm, the wrapper MUST add the `warden` hook entries to the Superpowers
  hook entries in the scratch copy. The scratch Superpowers skills MUST stay unchanged.
- **REQ-5.2** For an arm without `plugins/warden`, the wrapper MUST build the same scratch plugin
  that it builds today.
- **REQ-5.3** If a `warden` file has the same scratch path as a Superpowers file, the wrapper
  MUST exit 2 and name the path. It MUST NOT overwrite the file.
- **REQ-5.4** The wrapper MUST NOT check out a commit, and it MUST NOT write to the repository's
  git state.

*Proof: new offline cases in `tests/behavior/tests/runner.sh` with stub `claude`: a merged arm
whose scratch `hooks.json` holds the three entries, an old arm whose scratch tree matches today's
tree, and a collision that exits 2. The existing runner cases pass unchanged.*
*Source: decision H1. Constraint "Existing arms keep working".*

**REQ-6** The grader MUST support a comparator `both-at-least N` that gates both arms.

- **REQ-6.1** A `both-at-least` row MUST pass only when the baseline arm and the candidate arm
  each reach N graded hits with no errored run.
- **REQ-6.2** The record MUST show PASS or FAIL for the baseline arm of a `both-at-least` row.
  It MUST NOT show "report only" for that arm.
- **REQ-6.3** The grader MUST count a run under `both-at-least` the same way it counts a run under
  `at-least`.
- **REQ-6.4** The grader MUST exit 2 with a usage error for a `both-at-least` row whose baseline is
  `-`.
- **REQ-6.5** The grader MUST grade `at-least` and `at-most` rows exactly as it does at `7ac111f`.

*Proof: offline cases written before the code: both arms at 4/5 pass, a baseline at 3/5 fails, a
candidate at 3/5 fails, a `-` baseline exits 2. The tests of REQ-7 prove REQ-6.5.*
*Source: decision H2 and H3. Intent measure "baseline `7ac111f` and candidate both reach >= 4/5".*

### Data

**REQ-7** The test suite MUST prove that the existing arms files and run records grade exactly as
before.

- **REQ-7.1** Committed fixtures MUST reproduce the setup rows of records `726866` and `cbb2f3`.
  A fixture MUST hold only the fields the grader reads. A fixture MUST NOT hold `tracePath`,
  `promptMarkdown`, `dir`, `source` or a time.
- **REQ-7.2** The golden test MUST regrade each setup fixture and diff the result table rows and the
  run lines against the committed record. The diff MUST be empty. The test MUST NOT compare the
  record header.
- **REQ-7.3** Synthetic result files MUST point their `tracePath` values at committed traces in
  `tests/behavior/tests/traces/`. A test MUST grade them under `at-least`, `at-most` and
  `both-at-least`. The `at-least` and `at-most` verdicts MUST equal the verdicts that the grader
  at `7ac111f` gives.
- **REQ-7.4** The fixtures MUST pass `tests/no_machine_content.sh`.

*Proof: the golden test and the synthetic test pass. `tests/behavior/tests/graph_first.sh` passes
unchanged. `tests/no_machine_content.sh` passes.*
*Source: decisions H3, H4a and H4b. Intent "the existing arms files and run records still grade
exactly as before".*

**REQ-8** The wrapper MUST keep the traces it grades in the trace cache.

- **REQ-8.1** The wrapper MUST copy every trace into the run folder before the grader deletes the
  eval temp folders.
- **REQ-8.2** The wrapper MUST exit 2 before any agent starts when the trace cache is inside a git
  work tree.
- **REQ-8.3** After a run, the wrapper MUST delete the oldest run folders until 20 run folders
  remain.
- **REQ-8.4** The wrapper MUST NOT delete a trace cache entry that is not a run folder.
- **REQ-8.5** The record MUST name the model ID that the kept traces report. If the traces report
  more than one ID, the record MUST list each one. If no trace reports an ID, the record MUST
  write `unknown (no model ID in traces)`.

*Proof: offline runner cases with stub `claude`: traces present in the run folder after a run, a
cache inside a git work tree exits 2, 21 run folders become 20, a file such as `gate.sh` survives,
and the model ID from a stub trace appears in the record.*
*Source: decision H4c. Deferred finding 8 of PR #3: "The wrapper should read the model ID from a
trace before it deletes the traces."*

### Operations

**REQ-9** The pull request MUST carry the evidence for the move.

- **REQ-9.1** The pull request MUST link a run record in which read-order passes `both-at-least 4`
  with baseline `7ac111f` and the move commit as candidate.
- **REQ-9.2** The same record MUST show read-order-heldout at `at-least 4` for the move commit.
- **REQ-9.3** The pull request body MUST record a manual smoke check with both plugins installed
  through the installer. The check MUST show that the `warden` `SessionStart` hook fires, that the
  `warden` `SubagentStart` hook fires in a subagent, that the Superpowers hook fires, and that no
  skill or hook name collides.
- **REQ-9.4** The pull request body MUST state that the eval proof covers the merged plugin and
  not the real two-plugin install.

*Proof: a reviewer reads the pull request body and the linked record.*
*Source: intent measures for read-order, held-out and the smoke check.*

## Non-goals

- PR #2's setup check and its sandbox fix. They move onto the `warden` plugin in PR #2 after this
  change merges.
- The rerun of the three setup cases plus read-order on PR #2. That rerun belongs to PR #2.
- A skill in the `warden` plugin. The rule needs hooks only. PR #2 adds the first skill.
- Regrading the read-order rows of records `726866`, `a99c37` and `b23476`. Their traces are gone.
- Any change to the rule text.

## Constraints applied

Rules and area guides:

- `CLAUDE.md` (root): branch before the first change, conventional commits, test first, a
  pass-or-fail check for every change, reuse the existing helper. REQ-5 and REQ-8 extend the
  wrapper and the grader. They add no second harness.
- `rules/instruction-files.md`: read for the instruction-file rules. The rule text moves as it is.
- The 2026-09 spec, REQ-6: no machine path, no private marketplace. REQ-4.3 and REQ-7.4 keep
  `tests/no_machine_content.sh` passing. The `warden` marketplace is one this repository
  registers, so REQ-6.3 of that spec allows it.
- `tests/behavior/README.md`: no run touches a real project, the real `~/.claude`, or the git state
  of this repository. REQ-5.4 and REQ-8.2 keep that.

Policy skills: this is a configuration and tooling repository with no domain. No policy skill
applies.

## Open questions carried from intent

- **Answered.** How the rule reaches subagents. REQ-2 answers it with a `SubagentStart` hook.
- **Still open, answered by the plan's first task.** The real `claude plugin eval` traces were
  deleted, so nobody knows where a trace stores the model ID. The plan starts with one live
  run that keeps its trace and names the field. REQ-8.5 depends on it. Owner: Nicolai approves
  the run, because it uses plan usage.

## Design notes

- The grader deletes the eval temp folders in `cleanup()`. REQ-8.1 means the copy happens before
  that call.
- `grade_run()` inverts the `triggered` grader for every rule that is not `at-least`. REQ-6.3 means
  `both-at-least` takes the `at-least` branch.
- The trace cache already holds `gate.sh`, `gate-1.log` and `gate-heldout.log`. REQ-8.4 protects
  them.
- The retention count of 20 is a choice made in this spec. The intent allowed a run count or a
  maximum age.
