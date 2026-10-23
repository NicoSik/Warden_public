# Graphify Setup in Warden Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move PR #2's Graphify setup check into the `warden` plugin, make it fail cleanly in a shell where it cannot run, and remeasure it.

**Architecture:** The script moves to `plugins/warden/scripts/graphify-setup`. It gains a preflight, a config-first `setup` with rollback, the `unavailable` status word and exit 4. The warden `SessionStart` hook appends `hooks/setup-check.md` to the Code Map rule and fills in the script's quoted absolute path. The setup graders accept the quoted form.

**Tech Stack:** bash, python3 stdlib with `-I`, git, the offline test harnesses in `tests/`.

**Spec:** `docs/superpowers/changes/2026-10-graphify-setup-in-warden/spec.md`

## Global Constraints

- The blocked message is one stderr line: `graphify-setup: cannot run here: <what> does not run in this shell. Nothing was changed.` with `<what>` = `git` or `graphify`. For the config: `graphify-setup: cannot run here: .git/config is not writable. Nothing was changed.` For the notice marker: `graphify-setup: cannot run here: <marker folder> is not writable. Nothing was changed.` Every blocked case exits 4.
- When `git --version` fails, `status` prints `unavailable` on stdout before the blocked message.
- When `git --version` runs but the folder is not a git work tree, the script keeps PR #2's `not inside a git work tree` and exit 2.
- The config key is `warden.graphify`. The marker is `${XDG_CACHE_HOME:-$HOME/.cache}/warden/graphify-install-mentioned`. Nothing reads `superpowers.graphify`.
- The placeholder is `{{GRAPHIFY_SETUP}}`. `hooks/setup-check.md` holds it exactly once. The `SessionStart` output is `code-map.md` + `setup-check.md` with the placeholder replaced by the absolute path of `scripts/graphify-setup` inside the same plugin root. The command in the file reads `"{{GRAPHIFY_SETUP}}" status`, so the result is quoted.
- The hook finds the script as `$(dirname "$0")/../scripts/graphify-setup`, resolved to an absolute path. This works in the real plugin and in the merged eval arm.
- `SubagentStart` output stays `code-map.md` alone, byte for byte.
- `setup-check.md` names no plugin namespace and no skill.
- The new setup-grader pattern is `graphify-setup\W{1,3}status`.
- PR #2's source is commit `5a972be`: script `plugins/superpowers/skills/using-superpowers/scripts/graphify-setup`, tests `plugins/superpowers/tests/graphify-setup/test-graphify-setup.sh`, setup-check text in `plugins/superpowers/skills/using-superpowers/SKILL.md` from the line starting `**Setup check.**` to the end of its section. Read them with `git show 5a972be:<path>`.
- No test touches a real project, the real `~/.claude`, or the git state of this repository.

---

### Task 1: Freeze the new setup-grader pattern, test-first

**Satisfies:** REQ-8

**Files:**
- Create: `tests/behavior/tests/grader_patterns.sh`
- Modify: `tests/behavior/evals/setup-planning/graders/triggered.md`, `tests/behavior/evals/setup-quick-question/graders/triggered.md`, `tests/behavior/evals/setup-non-coding/graders/triggered.md` (the `input_match` line only)

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Brief:** `grader_patterns.sh` reads the `input_match` value from each of the three `triggered.md` files. It unescapes the YAML string to a regex, then runs Python `re.search` against five strings. The test asserts these results for each file:
1. `"/x/plugins/warden/scripts/graphify-setup status"` (unquoted): match.
2. `'"/x y/plugins/warden/scripts/graphify-setup" status'` (quoted): match.
3. The JSON encoding of string 2 as it sits inside a JSON object: `{"command":"\"/x y/plugins/warden/scripts/graphify-setup\" status"}`: match.
4. PR #2's old form `'/b/skills/brainstorming/../using-superpowers/scripts/graphify-setup status'`: match.
5. `'graphify-setup setup && echo status'`: no match.

The test also asserts that all three files hold the same pattern. Run it against the current pattern first, and see cases 2 and 3 fail. Then change the three files to `graphify-setup\\W{1,3}status` (YAML-escaped as the files escape today), and see every case pass. Then run `bash tests/behavior_harness.sh record_grading` to show that the golden setup fixtures still grade as before. Those fixtures replay stored verdicts, so the test file's header comment states that they do not test the pattern.

Test commands: `bash tests/behavior_harness.sh grader_patterns`, `bash tests/behavior_harness.sh record_grading`.

**Steps:**
- [ ] Write `grader_patterns.sh`. Run it and see cases 2 and 3 fail on all three files.
- [ ] Change the three `input_match` lines.
- [ ] Run `grader_patterns` and `record_grading` and see both pass.
- [ ] Commit: `test: freeze a setup-grader pattern that counts the quoted command`.

### Task 2: Move the script into warden with preflight, config-first setup and rollback

**Satisfies:** REQ-3, REQ-4, REQ-5, REQ-6, REQ-7

**Files:**
- Create: `plugins/warden/scripts/graphify-setup` (from `5a972be`, executable)
- Create: `tests/warden_graphify_setup.sh` (from `5a972be`'s test file, path updated)

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Brief:** Port PR #2's script and tests, then change the script as follows:
- **Names.** Rename `CONFIG_KEY` to `warden.graphify` and the marker folder to `warden`. Update the header comment: exit 4 means "cannot run in this shell".
- **Preflight in `main`.** First `git --version`. On failure, print `unavailable` on stdout if the command is `status`, print the git blocked message, and exit 4. Then keep PR #2's `git rev-parse --is-inside-work-tree` check with its exit 2.
- **`setup`.** Check `graphify --version` before any write, and print the graphify blocked message with exit 4 on failure. The script already checks it through `cli_available`; turn that into the blocked message.
  - Save the previous `warden.graphify` value first. Then set `warden.graphify` to `enabled` as the first write. On failure, print the `.git/config` blocked message and exit 4.
  - Every later failure restores the previous state, reusing PR #2's existing rollback for `graphify-out/`, the hooks, `.gitattributes` and `merge.graphify.*`. It also restores `.gitignore` byte for byte and resets `warden.graphify` to its saved value, or unsets it.
  - Success ends with `enabled` or `manual`, as in PR #2.
- **`decline`.** A failed config write prints the `.git/config` blocked message and exits 4.
- **`notice`.** A failed marker write prints the marker blocked message and exits 4. Remove any half-created folder.

Tests added to `tests/warden_graphify_setup.sh`, each comparing a snapshot of the previous state before and after:
1. A stub `git` first on `PATH` that fails `--version`: `status` prints `unavailable`, every command prints the git blocked message, and all exit 4.
2. A working `git` in a plain folder: `status` prints `not inside a git work tree` and exits 2, unchanged from PR #2.
3. A failing `graphify --version` during `setup`: graphify blocked message, exit 4, unchanged state.
4. A read-only `.git/config` (`chmod a-w`): `setup` and `decline` print the config blocked message, exit 4, unchanged state.
5. A fake graphify whose `update` fails after creating `graphify-out/`: unchanged state, PR #2's build-failure message.
6. An unwritable `.gitignore` after the first write: unchanged state, including `warden.graphify` reset.
7. A failing hook install: unchanged state. PR #2 already tests the hooks rollback, so this case extends it to `warden.graphify` and `.gitignore`.
8. An unwritable marker folder: `notice` prints the marker blocked message, exits 4, and leaves no new folder.
9. All of PR #2's existing cases pass with the new names.

Test command: `bash tests/warden_graphify_setup.sh`, then `bash tests/run.sh`.

**Steps:**
- [ ] Copy the script and the test file from `5a972be` and fix the test's script path. Rename the key and the marker in both. Run the tests and see PR #2's cases pass.
- [ ] Write tests 1–8. Run them and see them fail.
- [ ] Change the script.
- [ ] Run `bash tests/warden_graphify_setup.sh` and `bash tests/run.sh` and see every test pass.
- [ ] Run `grep -ri graphify plugins/superpowers` and see no output.
- [ ] Commit: `feat: move graphify-setup into warden and make it fail cleanly`.

### Task 3: Inject the setup check at session start with the script path

**Satisfies:** REQ-1, REQ-2

**Files:**
- Create: `plugins/warden/hooks/setup-check.md`
- Modify: `plugins/warden/hooks/code-map`
- Modify: `tests/warden_hooks.sh`
- Modify: `docs/superpowers/changes/2026-10-graphify-warden-plugin/spec.md` (one line under REQ-1.2: "Amended for SessionStart by `2026-10-graphify-setup-in-warden` REQ-1.")

**Depends on:** 2. The hook test checks that the real script exists and runs.

**Model:** `sonnet` (standard tier).

**Brief:**
- **`setup-check.md`.** Write PR #2's setup-check text from `5a972be`. Make these changes only:
  - The command line becomes `"{{GRAPHIFY_SETUP}}" status`.
  - The `$SETUP` sentence says that `$SETUP` stands for the same quoted path.
  - Add the bullet "`unavailable`: pass on the line the script printed, once, and continue without Graphify."
  - Remove "`<base directory>`" wording and any skill or namespace name.
- **The hook.** For `SessionStart`, print `code-map.md`, then `setup-check.md` with the one placeholder replaced by the resolved absolute script path. Escape the result with the existing `escape_for_json`. For `SubagentStart`, change nothing.
  - Exit 1 with no output when the script is missing or not executable.
  - Exit 1 with no output when `setup-check.md` does not hold the placeholder exactly once.
  - Read every file with the existing `cat … && printf x` pattern.

Tests added to `tests/warden_hooks.sh`:
1. The `SessionStart` `additionalContext` equals `code-map.md` + `setup-check.md`, with the placeholder replaced by the absolute path of `plugins/warden/scripts/graphify-setup`. The command appears as `"<path>" status`.
2. A copy of `plugins/warden` under a folder named `plugin root` (with a space). `SessionStart` output holds the quoted path with the space, and running that exact command from the output with `bash -c` in a temp git repo prints a status word.
3. `SubagentStart` output still equals `code-map.md` byte for byte. Keep the existing assertion.
4. `setup-check.md` holds `{{GRAPHIFY_SETUP}}` exactly once. A temp copy with zero and a copy with two placeholders each make the hook exit non-zero with empty stdout.
5. A copy without `scripts/graphify-setup` makes `SessionStart` exit non-zero with empty stdout.
6. `setup-check.md` holds no `warden:`, `superpowers:` or `skill` text.

Test command: `bash tests/warden_hooks.sh`, then `bash tests/run.sh`.

**Steps:**
- [ ] Write tests 1–6. Run them and see them fail.
- [ ] Write `setup-check.md` and change the hook.
- [ ] Add the amendment line to the old spec.
- [ ] Run `bash tests/warden_hooks.sh`, `bash tests/run.sh` and `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Commit: `feat: inject the graphify setup check at session start`.

### Task 4: Rerun the setup cases and read-order on the new head

**Satisfies:** REQ-9 (9.1)

**Files:**
- Create: `docs/superpowers/changes/2026-10-graphify-setup-in-warden/arms.conf`
- Create: `docs/superpowers/changes/2026-10-graphify-setup-in-warden/runs/<date>-<id>.md`

**Depends on:** 1, 2, 3

**Model:** session. 40 agent runs on plan usage, approved with this plan.

**Brief:** The candidate is the branch head after Task 3, and the baseline is `main` `18498db`. `arms.conf`:

```
setup-planning 18498db <head> at-least 4
setup-quick-question 18498db <head> at-most 1
setup-non-coding 18498db <head> at-most 1
read-order 18498db <head> both-at-least 4
```

**Steps:**
- [ ] Write `arms.conf` with the full SHAs.
- [ ] Run `tests/behavior/run-behavior --arms docs/superpowers/changes/2026-10-graphify-setup-in-warden/arms.conf --record-dir docs/superpowers/changes/2026-10-graphify-setup-in-warden/runs`.
- [ ] Show the Results table. Check that the record pins `Merge check: lib/merge_check.py`, not STUB. If a row fails, stop and report. Do not tune the harness.
- [ ] Read the first commands of two planning runs from the kept traces. Show that the agent ran the quoted command and received `unavailable` inside the eval sandbox.
- [ ] Commit: `test: record the setup and read-order rerun for graphify setup in warden`.

### Task 5: Smoke check of the real two-plugin load

**Satisfies:** REQ-9 (9.2)

**Files:** none committed. The result goes into the PR body.

**Depends on:** 3

**Model:** session.

**Brief:** Use Nicolai's normal login with no new token. Work in a scratch git repo with at least 20 source files and no graph. Run one `claude -p` session with `--plugin-dir <worktree>/plugins/superpowers --plugin-dir <worktree>/plugins/warden --settings '{"enabledPlugins":{"superpowers@superpowers-dev":false}}'` and a planning prompt.

**Steps:**
- [ ] From the transcript, show that the `SessionStart` context holds `"<worktree>/plugins/warden/scripts/graphify-setup" status`.
- [ ] Show that the agent ran that command and acted on the word it printed.
- [ ] Show that no Superpowers text holds a setup check.
- [ ] Write the result into the PR body draft.

### Task 6: Replace PR #2 and clean up its worktree

**Satisfies:** REQ-9 (9.3, 9.4)

**Files:** none. The work happens on the remote and in the PR body.

**Depends on:** 4, 5, and the final review

**Model:** session.

**Steps:**
- [ ] Write the PR #2 body from the reconciled spec. The known-issue section describes a graceful-failure fix. It does not claim sandbox support.
- [ ] Push with `git push --force-with-lease=feature/graphify-setup-on-first-use:5a972be fork HEAD:feature/graphify-setup-on-first-use`.
- [ ] Update the PR #2 body and title.
- [ ] Find the worktree that holds `feature/graphify-setup-on-first-use` with `git worktree list`. In it, run `git status --porcelain` and `git stash list`. If the tree is clean, remove it with `git worktree remove`. If it holds changes, stop and show them to Nicolai.
- [ ] Delete the stale local branch `feature/graphify-setup-on-first-use` after the worktree is gone.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2 | Different files and no dependency. Task 1 freezes the pattern before any eval run. |
| 2 | 3 | It needs the real script from Task 2. |
| 3 | 4, 5 | Session tasks with no shared file. Both need the code complete. |

After wave 3: the final review, the fix wave and the scoped re-review, then `reconciling-specs`, then Task 6.

## Requirement coverage

| REQ | Task |
|---|---|
| REQ-1 | 3 |
| REQ-2 | 3 |
| REQ-3 | 2 |
| REQ-4 | 2 |
| REQ-5 | 2 |
| REQ-6 | 2 |
| REQ-7 | 2 |
| REQ-8 | 1 |
| REQ-9 | 4, 5, 6 |

## Risks, worst first

1. **Rollback leaves a partial state (Task 2).** `setup` touches six things. Tests 5–7 compare a full snapshot before and after, not single files. Task 2 carries the most risk.
2. **The quoted path breaks in the merged eval arm.** The hook resolves the script from its own folder, and the merged arm keeps the same `hooks/` → `scripts/` layout. Task 4 reads the first commands to confirm it.
3. **The new grader pattern counts the wrong calls.** Case 5 of Task 1 must not match. The pattern allows at most three characters between the name and `status`.
4. **The force-push loses work.** `--force-with-lease` names the expected remote SHA `5a972be`. The old worktree is removed only when clean.
5. **The setup cases change for a reason other than the move.** The baseline is `main`, which has no setup check, so its count is 0 by design. The candidate criteria are PR #2's.

Ruled out:
- A `graphify-setup` skill (decision of 2026-10-23).
- Making setup work inside a sandbox, and any change to sandbox settings (intent).
- A probe write to `.git/config`. The config write goes first instead (decision of 2026-10-23).
