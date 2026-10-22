# Graphify Warden Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Code Map rule from the vendored Superpowers plugin into a new `warden` plugin, and teach the behavior harness to measure the move.

**Architecture:** The `warden` plugin holds one rule file and one hook script. The script answers `SessionStart` and `SubagentStart` with the rule file as `additionalContext`. The wrapper merges `warden` hooks into the scratch Superpowers plugin per arm, because `claude plugin eval` loads one plugin. The grader gains `both-at-least`, and the wrapper keeps traces in the trace cache.

**Tech Stack:** bash, python3 (stdlib only, run with `-I`), jq in tests only, `claude plugin eval`.

**Spec:** `docs/superpowers/changes/2026-10-graphify-warden-plugin/spec.md`

## Global Constraints

- The rule text is the `## Code Map` section of `plugins/superpowers/skills/using-superpowers/SKILL.md` at `7ac111f`, from its heading to the line before the next heading, ending with "Put these four steps in every subagent prompt that explores code."
- The `warden` `SessionStart` matcher is the identical string to the Superpowers one. Today: `startup|clear|compact`.
- The `SubagentStart` entry has no matcher.
- Hook scripts need no `jq` at run time. They escape JSON the way `plugins/superpowers/hooks/session-start` does (`escape_for_json`).
- No test or wrapper run touches a real project, the real `~/.claude`, or the git state of this repository. Test commits use `git commit-tree` and create no ref.
- The trace cache default is `$HOME/.cache/warden-behavior`. `WARDEN_BEHAVIOR_RAW_DIR` overrides it. A run folder name is six lowercase hexadecimal characters.
- Retention keeps the newest 20 run folders.
- Python runs as `python3 -I`. No new dependency.
- Every committed file passes `tests/no_machine_content.sh`.
- Conventional commits. One commit per task at least.

## File map

| File | Responsibility | Task |
|---|---|---|
| `plugins/warden/.claude-plugin/plugin.json` | Plugin manifest, name `warden` | 1 |
| `plugins/warden/.claude-plugin/marketplace.json` | Marketplace `warden`, one plugin `warden`, source `./` | 1 |
| `plugins/warden/hooks/hooks.json` | `SessionStart` and `SubagentStart` entries | 1 |
| `plugins/warden/hooks/code-map` | Hook script: prints the rule file as `additionalContext` for the event in `$1` | 1 |
| `plugins/warden/hooks/code-map.md` | The rule text | 1 |
| `tests/warden_hooks.sh` | Offline check of REQ-1 and REQ-2 | 1 |
| `tests/behavior/lib/record.py` | Grader: `both-at-least`, model ID | 2, 8 |
| `tests/behavior/tests/record_grading.sh` | Golden and synthetic grading tests | 2, 8 |
| `tests/behavior/tests/fixtures/` | Reduced setup fixtures, synthetic results | 2 |
| `tests/behavior/run-behavior` | Wrapper: merge, trace keep, cache guard, retention | 3, 4 |
| `tests/behavior/stubs/claude` | Stub: optional snapshot of the evaluated plugin | 3 |
| `tests/behavior/tests/runner.sh` | Offline wrapper cases | 3, 4 |
| `tests/behavior/README.md` | Harness docs | 3, 4 |
| `install.sh`, `uninstall.sh`, `settings.json`, `README.md` | Install wiring | 5 |
| `tests/install_deps.sh`, `tests/uninstall_restores.sh`, `tests/no_machine_content.sh`, `tests/readme_sections.sh` | Install tests | 5 |
| `plugins/superpowers/skills/using-superpowers/SKILL.md`, `plugins/superpowers/skills/subagent-driven-development/implementer-prompt.md` | Lose the Code Map section | 6 |
| `docs/superpowers/changes/2026-10-graphify-warden-plugin/arms.conf`, `runs/` | Gate arms and record | 9 |

## Tasks

### Task 1: The `warden` plugin and its hook check

**Satisfies:** REQ-1, REQ-2

**Files:**
- Create: `plugins/warden/.claude-plugin/plugin.json`, `plugins/warden/.claude-plugin/marketplace.json`, `plugins/warden/hooks/hooks.json`, `plugins/warden/hooks/code-map`, `plugins/warden/hooks/code-map.md`
- Test: `tests/warden_hooks.sh`

**Depends on:** none

**Model:** `sonnet` (standard tier). The task crosses files.

**Interfaces:**
- Produces: `plugins/warden/hooks/code-map <EventName>` prints `{"hookSpecificOutput":{"hookEventName":"<EventName>","additionalContext":"<rule text>"}}`. It reads `code-map.md` from its own directory (`$(dirname "$0")`), not from `CLAUDE_PLUGIN_ROOT`, so it works when Task 3 copies `hooks/` into another plugin.
- Produces: `hooks.json` commands are `"${CLAUDE_PLUGIN_ROOT}/hooks/code-map" SessionStart` and `"${CLAUDE_PLUGIN_ROOT}/hooks/code-map" SubagentStart`.
- Produces: marketplace name `warden`, plugin name `warden`, so the `enabledPlugins` key is `warden@warden`.

**Brief:** Build a hooks-only plugin. `code-map.md` is the rule text, extracted from `git show 7ac111f:plugins/superpowers/skills/using-superpowers/SKILL.md`. `tests/warden_hooks.sh` follows the `tests/lib/harness.sh` pass/fail style and asserts:
1. `code-map SessionStart` output parses with `jq`, `hookEventName` is `SessionStart`, and `additionalContext` equals `code-map.md` byte for byte.
2. The same for `code-map SubagentStart`.
3. `hooks.json` has exactly one `SessionStart` entry and one `SubagentStart` entry, and the `SubagentStart` entry has no `matcher`.
4. The `warden` `SessionStart` matcher equals the matcher in `plugins/superpowers/hooks/hooks.json`.
5. `code-map` with no argument or an unknown event exits non-zero and prints nothing on stdout.

Test command: `bash tests/warden_hooks.sh`.

**Steps:**
- [ ] Write `tests/warden_hooks.sh` with assertions 1–5.
- [ ] Run it and see it fail because `plugins/warden` does not exist.
- [ ] Extract the rule text from `7ac111f` into `code-map.md`. Check it with `diff <(git show 7ac111f:plugins/superpowers/skills/using-superpowers/SKILL.md | awk '/^## Code Map/{f=1} f&&/^## /&&!/Code Map/{exit} f') plugins/warden/hooks/code-map.md` and see no output.
- [ ] Write the manifests, `hooks.json` and the `code-map` script (bash, `escape_for_json` pattern from `plugins/superpowers/hooks/session-start`, `chmod +x`).
- [ ] Run `bash tests/warden_hooks.sh` and see every assertion pass.
- [ ] Commit: `feat: add the warden plugin that injects the Code Map rule`.

### Task 2: Grader golden tests and the `both-at-least` comparator

**Satisfies:** REQ-6, REQ-7

**Files:**
- Modify: `tests/behavior/lib/record.py` (`grade_run`, the gate block in `main`, conf parsing)
- Create: `tests/behavior/tests/record_grading.sh`
- Create: `tests/behavior/tests/fixtures/726866-setup.json`, `tests/behavior/tests/fixtures/cbb2f3-setup.json`, `tests/behavior/tests/fixtures/726866-setup.conf`, `tests/behavior/tests/fixtures/cbb2f3-setup.conf`, `tests/behavior/tests/fixtures/synthetic-read-order.json` (template; see below)

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Produces: conf rows `case base cand rule N` where `rule` is `at-least`, `at-most` or `both-at-least`.
- Produces: for `both-at-least`, the record row criterion reads `graph-first >= N` (or `triggered >= N`) for both arms, and the baseline verdict is `PASS` or `FAIL`.

**Brief:** First prove the grader unchanged, then add the comparator.

Fixtures. Build the setup fixtures once from `~/.cache/warden-behavior/726866/` and `~/.cache/warden-behavior/cbb2f3/`, keeping only setup cases. Keep only: top-level `cases`, `claudeVersion`, `partial`, `suite.modelOverride`. Per case: `name`, `arms.with[]`. Per run: `error`, `score`, `passed`, `turns`, `costUsd`, `graders[]` with `name` and `passed`. Drop `tracePath`, `promptMarkdown`, `dir`, `source` and all times. The `.conf` files hold the setup rows that each record lists in its Results table (read the committed records under `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/`). Do not commit the reduction script. The raw cache stays out of the repo.

Synthetic read-order: the test writes result JSON at run time whose `tracePath` values point at committed traces in `tests/behavior/tests/traces/`: four graph-first traces (for example `1_graph_then_read.jsonl`) and one read-first trace. The committed template holds relative trace names. The test resolves them to absolute paths in a temp copy.

`record_grading.sh` asserts:
1. Golden 726866: `record.py` on the fixture writes Results rows and `## Runs` lines that equal the setup lines of the committed record `2026-10-21-726866.md`. The diff is empty. The header is not compared.
2. Golden cbb2f3: the same against `2026-10-21-cbb2f3.md`.
3. Synthetic read-order results (4 of 5 runs graph-first), each verdict checked against `git show 7ac111f:tests/behavior/lib/record.py` run on the same input: `at-least 4` is PASS, `at-least 5` is FAIL, `at-most 1` is FAIL, and `at-most 4` is PASS.
4. `both-at-least 4`, baseline 4/5 and candidate 4/5: both rows PASS, exit 0.
5. `both-at-least 4`, baseline 3/5: baseline row FAIL, exit 1.
6. `both-at-least 4`, candidate 3/5: candidate row FAIL, exit 1.
7. `both-at-least 4` with baseline `-`: exit 2 and stderr names the row.
8. `both-at-least` on a setup case counts `triggered` the same way `at-least` does.
9. The fixtures contain no `tracePath` key.

Test command: `bash tests/behavior_harness.sh record_grading`.

**Steps:**
- [ ] Build and commit the reduced fixtures. Run `bash tests/no_machine_content.sh` and see it pass.
- [ ] Write assertions 1, 2, 3 and 9. Run them against the current `record.py` and see them pass. This proves the fixtures reproduce today's grading.
- [ ] Commit: `test: pin the grader to the committed setup records`.
- [ ] Write assertions 4–8. Run them and see them fail on the unknown rule.
- [ ] Change `record.py`: accept `both-at-least`, take the `at-least` branch in `grade_run`, gate the baseline arm for that rule, exit 2 for a `-` baseline.
- [ ] Run `bash tests/behavior_harness.sh` (all behavior tests, including `graph_first.sh` and `runner.sh`) and see every test pass.
- [ ] Commit: `feat: gate both arms with the both-at-least comparator`.

### Task 3: Merge the `warden` hooks into the scratch plugin per arm

**Satisfies:** REQ-5

**Files:**
- Modify: `tests/behavior/run-behavior` (the arm loop, around `git archive "$sha" plugins/superpowers`)
- Modify: `tests/behavior/stubs/claude` (snapshot)
- Modify: `tests/behavior/tests/runner.sh`
- Modify: `tests/behavior/README.md`

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Produces: stub env `STUB_SNAPSHOT_DIR`. When it is set, the stub copies the evaluated plugin directory (the positional target after `eval`) to `$STUB_SNAPSHOT_DIR/call-<n>/` before it writes results.

**Brief:** Archive `plugins/` for each arm. When the arm has `plugins/warden`, copy every file of `plugins/warden/hooks/` except `hooks.json` into the scratch `plugins/superpowers/hooks/`, and append each `warden` hook entry to the matching event array of the scratch `hooks.json`. If a copied file already exists, exit 2 with `merge collision: <path>`. When the arm has no `plugins/warden`, the scratch tree is the same as today. Document the merge and its limit (the proof covers the merged plugin, not the real install) in `tests/behavior/README.md`.

Arm commits for the tests: build them with `git commit-tree` from a temporary `GIT_INDEX_FILE`, starting from `7ac111f`'s tree, with no ref. One adds a minimal `plugins/warden` (hooks.json with both events, a `code-map` script, `code-map.md`). One also adds `plugins/warden/hooks/run-hook.cmd`, which collides.

New `runner.sh` cases assert:
1. Old arm (`7ac111f`): the snapshot has the same file list and the same `hooks.json` as `git archive 7ac111f plugins/superpowers`.
2. Warden arm: the snapshot `hooks.json` has the Superpowers `SessionStart` entry, the `warden` `SessionStart` entry and the `warden` `SubagentStart` entry. `hooks/code-map` and `hooks/code-map.md` exist. `skills/` equals the arm's `plugins/superpowers/skills/`.
3. Collision arm: exit 2, output names `hooks/run-hook.cmd`, no eval call.
4. The existing `STATUS_BEFORE` check still holds, and `git for-each-ref` output is unchanged.

Test command: `bash tests/behavior_harness.sh runner`.

**Steps:**
- [ ] Add `STUB_SNAPSHOT_DIR` to the stub.
- [ ] Write cases 1–4. Run them and see 2 and 3 fail.
- [ ] Change the arm loop in `run-behavior`.
- [ ] Run `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Update `tests/behavior/README.md`.
- [ ] Commit: `feat: merge warden hooks into the scratch plugin per arm`.

### Task 4: Keep traces in the trace cache, with a guard and retention

**Satisfies:** REQ-8 (8.1–8.4)

**Files:**
- Modify: `tests/behavior/run-behavior`
- Modify: `tests/behavior/tests/runner.sh`
- Modify: `tests/behavior/README.md`

**Depends on:** 3

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Produces: after a run, `$RAW_BASE/<id>/traces/<case>/<arm-sha7>/run-<i>.jsonl` holds every trace that the results name. Task 8 reads these files.

**Brief:** Before the wrapper calls `record.py` (whose `cleanup()` deletes the eval temp folders), copy every `tracePath` from every merged result into the run folder layout above. Before the cost prompt, resolve the trace cache to its nearest existing ancestor and exit 2 if `git -C <that> rev-parse --is-inside-work-tree` succeeds, naming `WARDEN_BEHAVIOR_RAW_DIR`. After the record is written, delete the oldest run folders (by modification time) until 20 remain. Touch only entries whose name matches `^[0-9a-f]{6}$`.

New `runner.sh` cases assert:
1. After a read-order run with 2 runs, the run folder holds 2 trace files with the stub trace content.
2. A trace cache inside a git work tree (a `git init` folder under `$T`): exit 2 before any eval call.
3. 21 pre-made run folders plus one new run: 20 remain, the oldest is gone.
4. A file `gate.sh` and a folder `notes` in the cache survive retention.
5. The existing record and raw-result cases still pass.

Test command: `bash tests/behavior_harness.sh runner`.

**Steps:**
- [ ] Write cases 1–4. Run them and see them fail.
- [ ] Add the trace copy, the guard and the retention to `run-behavior`.
- [ ] Run `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Update `tests/behavior/README.md` (trace cache, guard, retention of 20).
- [ ] Commit: `feat: keep graded traces in the trace cache`.

### Task 5: Install the `warden` plugin

**Satisfies:** REQ-4

**Files:**
- Modify: `install.sh` (`install_plugins`), `uninstall.sh` (the removal message), `settings.json` (`enabledPlugins`), `README.md` (marketplace row, file table)
- Modify: `tests/install_deps.sh`, `tests/uninstall_restores.sh`, `tests/no_machine_content.sh` (`check_settings_allowlist`), `tests/readme_sections.sh` if it pins the file table

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Brief:** Register `plugins/warden` the same way as `plugins/superpowers`, enable `warden@warden`, print `claude plugin marketplace remove warden` in the uninstall message, and describe the plugin in `README.md`. Tests assert:
1. `install_deps.sh`: the install log contains `claude plugin marketplace add $REPO_DIR/plugins/warden`, and the dry run says it would register the warden marketplace.
2. `install_deps.sh` F32 check: `warden` is an accepted marketplace id, asserted against `plugins/warden/.claude-plugin/marketplace.json`.
3. `uninstall_restores.sh`: the output contains `claude plugin marketplace remove warden`.
4. `no_machine_content.sh`: `warden@warden` passes the allowlist. A temp copy of `settings.json` with an extra `x@y` key still fails.

Test command: `bash tests/run.sh`.

**Steps:**
- [ ] Write assertions 1–4. Run `bash tests/run.sh` and see them fail.
- [ ] Change `install.sh`, `uninstall.sh`, `settings.json`, the allowlist and `README.md`.
- [ ] Run `bash tests/run.sh` and see every test pass.
- [ ] Commit: `feat: install the warden plugin next to superpowers`.

### Task 6: Delete the Code Map sections from Superpowers

**Satisfies:** REQ-3

**Files:**
- Modify: `plugins/superpowers/skills/using-superpowers/SKILL.md` (lines 34–43)
- Modify: `plugins/superpowers/skills/subagent-driven-development/implementer-prompt.md` (lines 75–83)

**Depends on:** 1

**Model:** `sonnet` (cheap tier mapped to sonnet). A pure deletion with a fixed check.

**Brief:** Delete each `## Code Map` section and the blank line that follows it. Change nothing else. This is a content edit with no new behavior, so it uses existing checks.

**Steps:**
- [ ] Delete the two sections.
- [ ] Run `grep -ri graphify plugins/superpowers` and see no output.
- [ ] Run `git diff 7ac111f -- plugins/superpowers` and see only the two deletions.
- [ ] Run `bash tests/run.sh` and `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Commit: `refactor: move the Code Map rule out of the vendored superpowers plugin`.

### Task 7: Live run to show the trace copy and find the model ID field

**Satisfies:** REQ-8 (8.1 live evidence; input for 8.5)

**Files:** none committed. The record goes to the scratchpad with `--record-dir`.

**Depends on:** 4

**Model:** session. It uses plan usage, approved on 2026-10-22.

**Brief:** Run the wrapper once with a scratch arms file holding `read-order-heldout - <HEAD sha> at-least 1`, `--runs 1`, and `--record-dir` in the scratchpad.

**Steps:**
- [ ] Run the wrapper and answer `y` at the prompt.
- [ ] Show that `~/.cache/warden-behavior/<id>/traces/read-order-heldout/<sha7>/run-1.jsonl` exists, and that the eval temp folder named in the result is gone. This shows the copy ran before `cleanup()`.
- [ ] Find the model ID field in the kept trace (for example `message.model` on assistant lines). Record the JSON path and one example value in the Task 8 brief before Task 8 starts.

### Task 8: Name the model ID in the record

**Satisfies:** REQ-8 (8.5)

**Files:**
- Modify: `tests/behavior/lib/record.py` (the `## Pins` model line)
- Modify: `tests/behavior/tests/record_grading.sh`

**Depends on:** 2, 7

**Model:** `sonnet` (cheap tier mapped to sonnet). One production file.

**Interfaces:**
- Consumes: the trace layout from Task 4 (`<raw-dir>/traces/...`) and the JSON path that Task 7 found.

**Brief:** `record.py` reads the model ID from every kept trace under `--raw-dir`. The `- Model:` pin lists each distinct ID, sorted. With no ID, it writes `unknown (no model ID in traces)`. Tests assert:
1. One stub trace with ID `claude-test-1`: the pin reads `claude-test-1`.
2. Two traces with two IDs: both are listed.
3. No ID: the pin reads `unknown (no model ID in traces)`.
4. The golden tests from Task 2 still pass (the header is not compared).

Test command: `bash tests/behavior_harness.sh record_grading`.

**Steps:**
- [ ] Write assertions 1–3. Run them and see them fail.
- [ ] Change the model pin in `record.py`.
- [ ] Run `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Commit: `feat: record the model ID from the kept traces`.

### Task 9: Gate run for the move

**Satisfies:** REQ-9 (9.1, 9.2)

**Files:**
- Create: `docs/superpowers/changes/2026-10-graphify-warden-plugin/arms.conf`
- Create: `docs/superpowers/changes/2026-10-graphify-warden-plugin/runs/<date>-<id>.md`

**Depends on:** 1, 3, 4, 6, 8

**Model:** session. 15 agent runs on plan usage, approved with this plan.

**Brief:** The candidate is the branch head after Task 8. `arms.conf`:

```
read-order 7ac111f <head sha> both-at-least 4
read-order-heldout - <head sha> at-least 4
```

**Steps:**
- [ ] Write `arms.conf` with the full head SHA.
- [ ] Run `tests/behavior/run-behavior --arms docs/superpowers/changes/2026-10-graphify-warden-plugin/arms.conf --record-dir docs/superpowers/changes/2026-10-graphify-warden-plugin/runs`.
- [ ] Show the Results table. If a row fails, stop and report. Do not tune the harness.
- [ ] Run `bash tests/no_machine_content.sh` on the record.
- [ ] Commit: `test: record the gate run for the warden plugin move`.

### Task 10: Smoke check of the real two-plugin install

**Satisfies:** REQ-9 (9.3, 9.4)

**Files:** none committed. The result goes into the PR body.

**Depends on:** 1, 5, 6

**Model:** session.

**Brief:** Install into a throwaway home, never the real `~/.claude`, `~/bin` or `~/.local/bin`. The installer writes to `$HOME/bin` and `$HOME/.local/bin`, so `HOME` is overridden too. `--skip-plugin-hook` keeps the installer out of this repository's shared `.git/hooks`.

**Steps:**
- [ ] Run `HOME=<scratchpad>/smoke-home CLAUDE_CONFIG_DIR=<scratchpad>/smoke-home/.claude ./install.sh --skip-plugin-hook` from this worktree.
- [ ] In a scratch repo with `graphify-out/graph.json`, run one `claude -p` session under the same `HOME` and `CLAUDE_CONFIG_DIR` that starts one `general-purpose` subagent.
- [ ] From the transcripts, show: the Superpowers `SessionStart` hook ran, the `warden` `SessionStart` hook ran, the `warden` `SubagentStart` hook ran in the subagent, and `hook_success` has no error.
- [ ] Run `claude plugin list` under the same config and show no duplicate skill or hook names.
- [ ] If the throwaway config cannot log in, stop and hand Nicolai the exact commands.
- [ ] Write the result and the merged-plugin limit into the PR body draft.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2, 3, 5 | Each task owns different files and depends on nothing. |
| 2 | 4, 6 | Task 4 depends on Task 3 (`run-behavior`, `runner.sh`). Task 6 depends on Task 1. |
| 3 | 7 | Live run. It depends on Task 4. |
| 4 | 8 | It depends on Task 2 (`record.py`) and on Task 7's field name. |
| 5 | 9, 10 | Session tasks with no shared file. Both need the code complete. |

After the last wave: the final review, the fix wave and the scoped re-review, then `reconciling-specs`, then the PR from `feature/graphify-warden-plugin` to `NicoSik/Warden_public` `main`.

## Requirement coverage

| REQ | Task |
|---|---|
| REQ-1 | 1 |
| REQ-2 | 1 |
| REQ-3 | 6 |
| REQ-4 | 5 |
| REQ-5 | 3 |
| REQ-6 | 2 |
| REQ-7 | 2 |
| REQ-8 | 4, 7, 8 |
| REQ-9 | 9, 10 |

## Risks, worst first

1. **The merged plugin differs from the real install (Task 3).** In the merged arm, `CLAUDE_PLUGIN_ROOT` points at the scratch Superpowers plugin. The `code-map` script reads `code-map.md` from its own directory, so it finds the file in both layouts. Task 10 checks the real layout. Task 3 carries the most risk.
2. **The golden test passes for the wrong reason (Task 2).** If the fixtures came from the same code they test, the test proves nothing. The test compares against committed records that the older grader wrote on 2026-10-21. It also passes before the grader changes.
3. **Retention deletes a file Nicolai keeps (Task 4).** The cache already holds `gate.sh` and two logs. Retention matches run folder names only, and case 4 proves it.
4. **The cache guard refuses a legitimate cache.** If `$HOME` is itself a git work tree, the default cache fails the guard. The error names `WARDEN_BEHAVIOR_RAW_DIR` as the way out.
5. **The model ID field is not in the trace (Task 7).** Then REQ-8.5 writes `unknown (no model ID in traces)` on every run. Task 7 stops and reports this before Task 8 starts.
6. **A Superpowers refresh changes its matcher.** Task 1's assertion 4 fails on the next test run.

Ruled out:
- A `warden` skill. The rule needs hooks only (spec Non-goals).
- `jq` at hook run time. A fresh machine may not have it.
- A `--plugin-dir`-based runner. Nicolai chose the merged plugin.
- Committing raw cached results. Only reduced fixtures go in.
