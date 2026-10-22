# Warden Plugin Full Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge every file of `plugins/warden/` into an eval arm's scratch plugin, and fail the run when any `warden` file is missing from the merged arm.

**Architecture:** The wrapper archives all of `plugins/warden/` per arm. It copies every file into the scratch Superpowers plugin at the same relative path, merges `hooks/hooks.json` as JSON, and leaves out the two `warden` manifest files. A new checker, `lib/merge_check.py`, then compares the `warden` tree with the merged tree and exits 2 on any missing or different file.

**Tech Stack:** bash, python3 stdlib run with `-I`, the existing offline runner with stub `claude`.

**Spec:** `docs/superpowers/changes/2026-10-warden-plugin-full-merge/intent.md` (bounded change, no spec).

## Global Constraints

- An arm without `plugins/warden` builds the same scratch tree as today. Runner case 15a must pass unchanged.
- The merged arm keeps the Superpowers manifest. `plugins/warden/.claude-plugin/plugin.json` and `plugins/warden/.claude-plugin/marketplace.json` stay out of the merged arm.
- Any other file under `plugins/warden/.claude-plugin/` makes the wrapper exit 2 with `unexpected warden manifest file: .claude-plugin/<name>` before any eval.
- A `warden` file whose relative path already exists in the scratch Superpowers plugin makes the wrapper exit 2 with `merge collision: <relative path>` before any eval. `hooks/hooks.json` is the one exception: it merges as JSON.
- After the merge, every `warden` file except the two manifest files and `hooks/hooks.json` must exist in the merged arm, byte-equal. Otherwise the wrapper exits 2 with `merge incomplete: <relative path>` before any eval.
- No test or run touches a real project, the real `~/.claude`, or the git state of this repository. Synthetic arms use `git commit-tree` from a temporary `GIT_INDEX_FILE` and create no ref.
- Python runs as `python3 -I`. No `__pycache__` beside `lib/`.
- When `WARDEN_BEHAVIOR_MERGE_CHECK` is set, the wrapper prints `warning: WARDEN_BEHAVIOR_MERGE_CHECK is set; this run is a test run and grades nothing` to stderr. It passes `--merge-check-stub` to `record.py`. The record pins `- Merge check: STUB`. Every result row reads `STUB` in the result column, never `PASS` or `FAIL`. The grader exits 1. Without the variable, the record pins `- Merge check: lib/merge_check.py`.

---

### Task 1: Merge the whole `warden` plugin and check the merged arm

**Files:**
- Modify: `tests/behavior/run-behavior` (the merge block after `git archive "$sha" plugins/superpowers`, about lines 108–133)
- Create: `tests/behavior/lib/merge_check.py`
- Create: `tests/behavior/tests/merge_check.sh`
- Modify: `tests/behavior/lib/record.py` (`--merge-check-stub` flag, the `## Pins` merge-check line, the result column)
- Modify: `tests/behavior/tests/runner.sh` (`mkarm` and cases 15b–15c; new cases 15d–15f)
- Modify: `tests/behavior/README.md` (the merge paragraph)

**Depends on:** none

**Model:** `sonnet` (standard tier). The task crosses files.

**Interfaces:**
- Produces: `python3 -I tests/behavior/lib/merge_check.py <warden_dir> <merged_dir>`. It walks every file under `<warden_dir>` and skips `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and `hooks/hooks.json`. For each other file it checks that `<merged_dir>/<relative path>` exists and is byte-equal. It prints `merge incomplete: <relative path>` to stderr for the first failure and exits 2. Otherwise it exits 0 and prints nothing.

**Brief:** Today the wrapper archives only `plugins/warden/hooks`. PR #2 adds a `warden` skill, which would never reach the eval. Change the merge so that it does these things:
1. It archives `plugins/warden` whole when `"$sha:plugins/warden"` exists.
2. It exits 2 on an unexpected manifest file.
3. It copies every other file to the same relative path under the scratch `plugins/superpowers/`, with `cp -p` to keep modes. A collision exits 2.
4. It merges `hooks/hooks.json` with the existing JSON merge.
5. It runs `merge_check.py` on the archived `warden` tree and the scratch plugin. A non-zero exit stops the run with exit 2 before any eval.

Update the README paragraph to say that the merge copies the whole plugin except its manifest. Add this limit next to the merged-plugin limit: "In the merged arm a `warden` skill loads as `superpowers:<name>`. The setup grader counts Bash calls to `graphify-setup ... status`, so the name does not change its count. PR #2's smoke check covers the real `warden:<name>` load."

Tests:
- `tests/behavior/tests/merge_check.sh` (new, `tests/lib/harness.sh` pass/fail style) builds temp trees.
  1. A full copy exits 0 with empty output.
  2. A merged tree with one skill file deleted exits 2 and names `skills/demo/SKILL.md`.
  3. A merged tree where one file differs by one byte exits 2 and names it.
  4. The two manifest files and `hooks/hooks.json` absent from the merged tree still exit 0.
- `runner.sh`:
  - Extend `mkarm` so the `warden` arm also holds `skills/demo/SKILL.md`, `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
  - 15b also asserts that the snapshot has `skills/demo/SKILL.md` byte-equal to the arm's file. It also asserts that the snapshot `.claude-plugin/plugin.json` is still the Superpowers one.
  - New 15d: an arm whose `warden` holds `.claude-plugin/extra.json` exits 2. The output names `.claude-plugin/extra.json`, and no eval is called.
  - New 15e: an arm whose `warden` holds `skills/brainstorming/SKILL.md` collides with Superpowers. It exits 2, names `skills/brainstorming/SKILL.md`, and no eval is called.
  - New 15f: an end-to-end check that the wrapper acts on the checker's exit code. A correct merge never drops a file, so no arm can make the real checker fail through the wrapper. Instead, set `WARDEN_BEHAVIOR_MERGE_CHECK` to a stub script that exits 2 with `merge incomplete: x`. The wrapper must use that variable when it is set, and default to `lib/merge_check.py` otherwise. Assert exit 2, the message, and no eval call.
  - New 15g: `WARDEN_BEHAVIOR_MERGE_CHECK` points at a stub script that exits 0. Use a `warden` arm and a normal stub eval. Assert that stderr holds the warning line, that the record holds `- Merge check: STUB`, that no result row holds `PASS`, that every result row holds `STUB`, and that the wrapper exits 1.
  - Extend case 6 (the record case): a run without the variable pins `- Merge check: lib/merge_check.py`.
  - New 15h, before and after: build the old arm `7ac111f` twice and diff the two snapshots with `diff -r`. "Before" uses the wrapper and `tests/behavior/lib/` from `git show 7ac111f:...`, placed in a temp folder `$T/old/tests/behavior/`, with `$T/old/tests/behavior/evals` copied from this tree and a file `$T/old/.git` that holds `gitdir: <this repo's git dir>` (from `git rev-parse --absolute-git-dir`). The old wrapper finds the repo as its grandparent folder and runs only read-only git there. "After" uses the changed wrapper. The diff must be empty, excluding the `warden-evals/` folder that each wrapper copies in. Use `7ac111f` because it stays in `main`'s history; the PR #5 commits change SHA when the branch rebases. If the old wrapper cannot run this way, report BLOCKED with the error instead of changing the approach.
  - 15a and 15c pass unchanged.

Test commands: `bash tests/behavior_harness.sh merge_check`, `bash tests/behavior_harness.sh runner`, then `bash tests/behavior_harness.sh` and `bash tests/run.sh`.

**Steps:**
- [ ] Write `merge_check.sh` cases 1–4. Run them and see them fail (no `merge_check.py`).
- [ ] Write `lib/merge_check.py`. Run `merge_check.sh` and see it pass.
- [ ] Extend `mkarm` and write runner cases 15b additions, 15d, 15e, 15f, 15g, the case 6 addition and 15h. Run `runner` and see the new ones fail. 15h may pass before the change; record its output as the baseline.
- [ ] Change the merge block in `run-behavior`, including `WARDEN_BEHAVIOR_MERGE_CHECK`, its warning and `--merge-check-stub`.
- [ ] Add `--merge-check-stub` and the merge-check pin to `record.py`.
- [ ] Run `bash tests/behavior_harness.sh` and `bash tests/run.sh` and see every test pass.
- [ ] Update `tests/behavior/README.md`.
- [ ] Commit: `feat: merge the whole warden plugin into eval arms and check the merge`.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1 | One indivisible change. The wrapper, its checker and its tests describe one merge. Split, the runner cases could not pass without the wrapper change. |

After the last wave: the final review, the fix wave and the scoped re-review. This is a bounded change, so there is no `reconciling-specs`. Then the PR, rebased onto `main` after PR #5 merges.

## Risks, worst first

1. **A real `warden` skill collides with a Superpowers skill name.** The wrapper then exits 2 and runs no eval. That is the intended outcome, because a silent overwrite would test the wrong skill. Case 15e proves it.
2. **The merge check passes for the wrong reason.** A checker that compares the merged tree with itself would always pass. `merge_check.sh` cases 2 and 3 run it on trees that differ. Case 15f proves the wrapper acts on its exit code.
3. **Old arms change.** Case 15a compares the old arm's scratch tree with `git archive` byte for byte.
4. **`WARDEN_BEHAVIOR_MERGE_CHECK` is a test seam in production code.** It defaults to the real checker. When set, the wrapper warns, the record says STUB, and no row can pass, so a stubbed run can never serve as evidence. Case 15g proves it. The README names it as a test-only override.
5. **The before-and-after case depends on the old wrapper running from a temp folder.** It uses a `.git` file and read-only git only. If it cannot run, the implementer stops and reports.

Ruled out:
- Copying the `warden` manifest into the merged arm. It collides with the Superpowers manifest (decision D1).
- Renaming `warden` skills to keep a `warden:` namespace in the eval. `claude plugin eval` names every skill after the one plugin it loads (decision D2).
