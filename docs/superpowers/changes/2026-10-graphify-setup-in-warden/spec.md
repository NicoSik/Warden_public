# Spec: graphify-setup-in-warden

Intent: `intent.md`. Date: 2026-10-23. Status: approved.

## Summary

This change moves PR #2's Graphify setup check from the vendored Superpowers plugin into the
`warden` plugin. The script learns to detect a shell where it cannot run, to say so in one
message, and to leave no partial state. Unsandboxed sessions keep PR #2's behavior.

Size: 9 requirements from 16 intent items.

## Terms

- **The script** is `plugins/warden/scripts/graphify-setup`.
- **The setup-check file** is `plugins/warden/hooks/setup-check.md`.
- **The placeholder** is the literal text `{{GRAPHIFY_SETUP}}`.
- **The hook** is `plugins/warden/hooks/code-map`.
- **The blocked message** is one line on stderr:
  `graphify-setup: cannot run here: <what> does not run in this shell. Nothing was changed.`
  `<what>` is `git`, `graphify` or `.git/config`. For `.git/config` the line reads
  `graphify-setup: cannot run here: .git/config is not writable. Nothing was changed.`
- **Exit 4** is the new exit code for the blocked message.
- **The previous state** is the state of the repository and the machine before a command
  ran: the `warden.graphify` config value, `.gitignore`, `.gitattributes`, `graphify-out/`,
  the hooks directory, the `merge.graphify.*` config keys and the notice marker file.

## Requirements

### Behavior

**REQ-1** The hook MUST give the main session the Code Map rule and the setup check when a
session starts.

- **REQ-1.1** For `SessionStart`, the injected context MUST equal `code-map.md` followed by
  the setup-check file, byte for byte, except that the hook MUST replace the placeholder with
  the script's absolute path.
- **REQ-1.2** The injected command MUST quote the path: `"<absolute path>" status`.
- **REQ-1.3** For `SubagentStart`, the injected context MUST stay `code-map.md` alone, byte
  for byte.
- **REQ-1.4** The hook MUST exit non-zero with no output when the script is missing or not
  executable.

*Proof: `tests/warden_hooks.sh` runs the hook for both events from a copy of the plugin whose
root folder name contains a space. It asserts the substitution, the quotes, that the path
exists and is executable, the unchanged `SubagentStart` output, the missing-script exit, and
that the setup-check file contains the placeholder exactly once.*
*Source: decisions of 2026-10-22 and 2026-10-23 (SessionStart only, file plus filled path,
quoted path, exactly one placeholder). Amends REQ-1.2 of `2026-10-graphify-warden-plugin`.*

**REQ-2** The setup-check file MUST carry PR #2's setup-check wording and actions.

- **REQ-2.1** The file MUST name no plugin namespace and no `graphify-setup` skill. It MUST
  keep PR #2's trigger sentence, which names the four Superpowers skills that start the check.
- **REQ-2.2** The file MUST add one action: on `unavailable`, pass on the script's message
  once and continue without Graphify.
- **REQ-2.3** The file MUST NOT change any other action of PR #2's setup check.
- **REQ-2.4** The file MUST NOT carry the Code Map steps. `code-map.md` carries them.

*Proof: `tests/warden_hooks.sh` checks the trigger sentence against PR #2's sentence, kept as a
literal from `5a972be`, byte for byte. It also checks that the file names the four skills, that
the file holds no `graphify query`, and that the SessionStart context holds it exactly once.*
*Source: decision of 2026-10-23 (no skill). Intent outcome "status prints `unavailable`".*

**REQ-3** The script MUST stop with the blocked message when git does not run.

- **REQ-3.1** When `git --version` fails, every command MUST print the blocked message for
  `git` and exit 4.
- **REQ-3.2** In that case, `status` MUST print `unavailable` on stdout before it exits.
- **REQ-3.3** When `git --version` runs but the directory is not a git work tree, the script
  MUST keep PR #2's behavior: `not inside a git work tree` on stderr and exit 2.
- **REQ-3.4** A command MUST NOT write anything before these checks pass.
- **REQ-3.5** When the graphify binary is on PATH but `graphify --version` fails, `status`
  MUST print `unavailable` on stdout, then the blocked message for `graphify`, and exit 4.

*Proof: `tests/warden_graphify_setup.sh` runs each command with a stub `git` that fails
`--version`, and separately in a plain folder with a working `git`. Each case asserts the
output, the exit code and an unchanged previous state.*
*Source: decision of 2026-10-23 (two git cases, tested separately). Intent constraint "No
partial state".*

**REQ-4** `setup` MUST leave the previous state unchanged when it fails.

- **REQ-4.1** When the graphify binary is on PATH but `graphify --version` fails, `setup`
  MUST print the blocked message for `graphify` and exit 4. When the binary is not on PATH,
  `setup` MUST keep PR #2's install hint and exit 1.
- **REQ-4.2** The first write of `setup` MUST set `warden.graphify`. When that write fails,
  `setup` MUST print the blocked message for `.git/config` and exit 4.
- **REQ-4.3** When a step after the first write fails, `setup` MUST restore the previous
  state and then exit non-zero. The message MUST name the failed step and say that setup
  rolled back its changes.
- **REQ-4.4** When `setup` succeeds, `warden.graphify` MUST hold `enabled` or `manual`, as in
  PR #2.
- **REQ-4.5** When the final `warden.graphify` write fails after `setup` installs the hooks,
  `setup` MUST exit non-zero. Its message MUST name each hook file that stays installed and
  the removal command `graphify hook uninstall`. This case leaves the hooks installed. It is
  a known limit.

*Proof: `tests/warden_graphify_setup.sh` covers a failing graphify binary, a failing config
write (a leftover `.git/config.lock`, because `chmod a-w` does not stop git's lock-and-rename
write), a failing graph build with an existing `graphify-out/`, a failing `.gitignore` write
and a failing hook install. Each case compares the previous state before and after. A last
case covers the REQ-4.5 limit.*
*Source: decision of 2026-10-23 (config write first, rollback as backup). Intent constraint
"No partial state".*

**REQ-5** `decline` and `notice` MUST make at most one write.

- **REQ-5.1** When the `decline` write fails, `decline` MUST print the blocked message for
  `.git/config`, exit 4 and change nothing.
- **REQ-5.2** When the `notice` marker write fails, `notice` MUST print
  `graphify-setup: cannot run here: <marker folder> is not writable. Nothing was changed.`,
  exit 4 and change nothing.

*Proof: `tests/warden_graphify_setup.sh` runs both with an unwritable target.*
*Source: intent constraint "No partial state".*

### Data

**REQ-6** The script MUST use the new names.

- **REQ-6.1** The script MUST record the decision in the local git config key
  `warden.graphify`.
- **REQ-6.2** The script MUST keep the notice marker at
  `${XDG_CACHE_HOME:-$HOME/.cache}/warden/graphify-install-mentioned`.
- **REQ-6.3** The script MUST NOT read or migrate `superpowers.graphify`.

*Proof: `git grep -n 'superpowers.graphify\|cache}/superpowers' plugins tests` prints
nothing. The tests assert both names.*
*Source: decision G2 of 2026-10-23 (rename without migration).*

### Interface

**REQ-7** The Superpowers plugin MUST NOT carry Graphify content.

- **REQ-7.1** The setup-check text and the script MUST NOT exist under `plugins/superpowers`.
- **REQ-7.2** PR #2's tests MUST run from `tests/warden_graphify_setup.sh`, so `tests/run.sh`
  runs them.

*Proof: `grep -ri graphify plugins/superpowers` prints nothing. `tests/run.sh` lists
`warden_graphify_setup.sh`.*
*Source: intent constraint "The Superpowers plugin carries no Graphify content".*

**REQ-8** The setup graders MUST count the quoted command form.

- **REQ-8.1** The `triggered` grader of each setup case MUST match an unquoted
  `graphify-setup status` and a quoted `"…/graphify-setup" status`.

*Proof: `tests/behavior/tests/grader_patterns.sh` runs the pattern of each setup grader against
the five strings in the C1 ruling. The rerun record shows the candidate arm's counts.*
*Source: decision of 2026-10-23 (quoted path) against the existing grader. See C1.*

### Operations

**REQ-9** PR #2 MUST carry the evidence for this change.

- **REQ-9.1** The PR MUST link run records for the three setup cases and read-order, with
  `18498db` (`main`) as baseline. The candidate MUST be the commit that carries the final
  `setup-check.md` and hook: `061293f`, in records `e19c49` (setup cases) and `d8ff7d`
  (read-order). Each record MUST explain why later commits cannot change its results. The setup criteria
  stay: planning `at-least 4`, quick question `at-most 1`, non-coding `at-most 1`. Read-order
  uses `both-at-least 4`.
- **REQ-9.2** The PR body MUST record a smoke check in the real two-plugin load. The check
  MUST show that the injected setup-check text holds a quoted absolute path to the branch's
  `plugins/warden/scripts/graphify-setup`, and that the agent runs that command.
- **REQ-9.3** The PR's known-issue section MUST describe a graceful-failure fix: in a
  sandboxed session the script prints one message, `status` prints `unavailable`, and nothing
  changes. It MUST NOT claim that setup works in a sandbox.
- **REQ-9.4** The rebased branch MUST replace PR #2's remote branch with
  `--force-with-lease`. After a check of its state, the controller MUST remove the old
  worktree that holds PR #2's branch.

*Proof: a reviewer reads the PR body, the linked record and `git worktree list`.*
*Source: intent measures. Decisions of 2026-10-23 (force-push, worktree).*

## Non-goals

- Setup that works inside a sandbox. Nicolai does not use the sandbox in his own sessions.
- Any change to sandbox settings.
- Changes to the setup flow: ask once, a decline is final, the script skips small
  repositories, the install notice appears once.
- A `graphify-setup` skill. The setup-check file carries the instructions.

## Constraints applied

Rules and area guides:

- `CLAUDE.md` (root): branch before the first change, conventional commits, test first, a
  pass-or-fail check for every change, `--force-with-lease` on an own branch only.
- `2026-10-graphify-warden-plugin/spec.md`: this spec amends its REQ-1.2 for `SessionStart` only.
  REQ-1.4 (non-zero exit with no output, never blocking) now covers a missing script too.
- `2026-10-warden-plugin-full-merge`: the merged eval arm copies `plugins/warden/scripts/`
  into the scratch plugin. The script path in the merged arm is therefore
  `<scratch>/plugins/superpowers/scripts/graphify-setup`. The hook computes it from its own
  folder in both layouts.
- `tests/no_machine_content.sh`: no machine path in any committed file.

Policy skills: this is a configuration and tooling repository with no domain. No policy skill
applies.

## Flagged concerns

**C1. The quoted path breaks the setup graders.** The decision of 2026-10-23 requires
`"<path>" status`. The three setup graders use `input_match: "graphify-setup[^\"]*\\bstatus"`.
The match runs over the tool input, where the quote after `graphify-setup` stops `[^\"]*`. The
setup cases would then score 0 for a harness reason. Options:

- **C1-a (recommended).** Change the three graders to `graphify-setup\\W{1,3}status`. It
  matches `graphify-setup status`, `graphify-setup" status` and the JSON-escaped
  `graphify-setup\" status`. It still cannot run across other fields. Cost: the grader changes
  between the old records and the rerun. The old candidate `5a972be` used the unquoted form,
  which both patterns match.
- **C1-b.** Inject the path unquoted. Cost: a plugin root with a space breaks the command,
  which the decision rules out.
- **C1-c.** Quote only when the path contains a space. Cost: two forms to test, and the
  graders still fail on the quoted form.

Owner: Nicolai.

**Ruling 2026-10-23: C1-a.** The plan builds it test-first. An offline check runs the new
pattern against the unquoted form, the quoted form, the JSON-escaped form, PR #2's old command
form and one string that must not match. The pattern is frozen in a commit before any eval
run. PR #5's golden setup fixtures rerun to show that `record.py` grades the old records
unchanged. Those fixtures replay the stored grader verdicts, so they cannot test the pattern
itself. The old traces are gone, so the offline check is the evidence for the pattern.

## Open questions carried from intent

- **Answered.** The config key name and the carry-over of `superpowers.graphify`: REQ-6 (new
  name, no migration).
- **Still open, answered in the plan.** Whether `input_match` runs over the raw command or over
  the JSON-encoded tool input. C1-a matches both. The plan's first task checks it with one
  offline run of the grader pattern against both strings.

## Reconciled 2026-10-23

- REQ-2.1 — the spec forbade naming any skill. The restored PR #2 trigger names the four
  skills that start the check. Ruling: the spec was wrong.
- REQ-2.3 and new REQ-2.4 — PR #2's section also held the old Code Map steps. The build
  removed them, because `code-map.md` carries the current rule. Ruling: the spec was wrong.
- REQ-3.5 — new. A graphify binary that is present but fails makes `status` print
  `unavailable`. Ruling: the spec was wrong.
- REQ-4.1 — an absent binary keeps PR #2's install hint and exit 1. Ruling: the spec was wrong.
- REQ-4.3 — the spec asked for PR #2's messages. PR #2's hook-failure text claimed the graph
  stays built. Ruling: the spec was wrong. Two more messages still said "graph built" after
  a full rollback. Ruling: the code was wrong, and the code now says that setup rolled back its changes.
- REQ-4.5 — new. A failed final config write after hook install leaves the hooks installed.
  Ruling: the spec was wrong, recorded as a known limit. The message names what stays
  installed and how to remove it.
- REQ-4 proof — a leftover `.git/config.lock` models the blocked config write. Ruling: the spec
  was wrong.
- REQ-5.2 — the message says "is not writable". Ruling: the spec was wrong.
- REQ-9.1 — the candidate is `061293f`, not the final head. Later commits change no file under
  `plugins/warden/hooks`, and no graded run reached code past the preflight. Ruling: the spec
  was wrong.
