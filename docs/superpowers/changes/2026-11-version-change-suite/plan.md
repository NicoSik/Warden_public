# Version Change Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The weekly job detects a model or CLI minor change and names the suite command, and `warden-lesson suite` runs every behavior case on main and compares it with the suite record of the previous version.

**Architecture:** Two new stdlib modules beside the ledger module hold the shared logic: `warden_pins.py` reads the current pins, and `warden_suite.py` reads summaries and computes the combined view and coverage. The wrapper gets per-arm models and a suite mode. The recorder writes a JSON summary in suite mode. A new `tests/behavior/lib/suite_compare.py` prints the comparison and loads `warden_suite.py` by path. The weekly run and `status` in the ledger module call the two new modules.

**Tech Stack:** Python 3 standard library only (run with `python3 -I`), bash, git, launchd plist through `plistlib`. Tests are bash scripts on `tests/lib/harness.sh` with stub `claude`, `graphify`, `osascript` and `launchctl`.

**Spec:** `docs/superpowers/changes/2026-11-version-change-suite/spec.md` (approved, `2ada0b1`). Intent: `intent.md` in the same folder.

## Global Constraints

- No test starts a real `claude`. Every test runs offline. (REQ-9.1)
- `bash tests/run.sh` and `bash tests/behavior_harness.sh runner` pass at the end of every task. (REQ-9.2, REQ-9.3)
- Python code runs as `python3 -I` and imports only the standard library.
- Nothing with a home path is committed. `tests/no_machine_content.sh` checks it.
- The weekly run never starts an eval, and it never calls the wrapper. (REQ-5.11)
- The weekly run keeps only the model ID and the line count from transcripts. (REQ-4.7)
- Existing Markdown records keep their format. The golden tests in `tests/behavior/tests/record_grading.sh` pass unchanged. (REQ-2.5, REQ-6.4)
- Existing output of `report`, `list`, `status`, `mark`, `weekly` and `schedule` stays unchanged, except for the new lines this plan names.
- Output strings are exact. Copy them from the task's Interfaces block.
- Commit messages are conventional commits (`feat:`, `fix:`, `test:`, `docs:`).
- Tool flags must work on macOS (BSD `stat`, `sed`, `date`).

## File map

| File | Responsibility | Task |
|---|---|---|
| `tests/behavior/run-behavior` | Per-arm model, then suite mode and the comparison call | 1, 4, 7 |
| `tests/behavior/lib/record.py` | Per-arm model rows, then the summary | 1, 4 |
| `tests/behavior/stubs/claude` | Writes the `--model` value into stub traces | 1 |
| `tests/behavior/evals/suite.conf` | Suite criteria, new | 4 |
| `tests/behavior/lib/suite_compare.py` | Prints the comparison, new | 5 |
| `tests/behavior/tests/runner.sh` | Wrapper tests | 1, 4, 7 |
| `tests/behavior/tests/record_grading.sh` | Recorder and golden tests | 1, 4 |
| `tests/behavior/tests/suite_compare.sh` | Comparison tests, new | 5 |
| `tests/behavior/README.md` | Suite mode and the sixth column | 4 |
| `.gitignore` | Ignores `__pycache__/` | 4 |
| `plugins/warden/scripts/warden_suite.py` | Summary reading, combined view, coverage, new | 2 |
| `plugins/warden/scripts/warden_pins.py` | Current pins from `claude` and transcripts, new | 3 |
| `plugins/warden/scripts/warden_ledger.py` | Weekly run, status lines, schedule install | 6 |
| `plugins/warden/scripts/warden-lesson` | The `suite` subcommand | 7 |
| `tests/warden_suite.sh` | Unit tests for `warden_suite.py`, new | 2 |
| `tests/warden_pins.sh` | Unit tests for `warden_pins.py`, new | 3 |
| `tests/warden_ledger.sh` | Weekly, status and schedule tests | 6 |
| `tests/warden_lessons.sh` | `suite` subcommand pass-through test | 7 |
| `README.md` | The `suite` command and the new status lines | 7 |

## Shared interfaces

These definitions are copied into every task that uses them.

**Summary file.** Name: `<UTC date YYYY-MM-DD>-<id>.json` beside `<UTC date>-<id>.md`. Content (one JSON object):

```json
{"schema": 1, "id": "69257e", "date": "2026-11-27T10:00:00Z",
 "sha": "<40 hex>", "cli_version": "2.1.331", "cli_version_raw": "2.1.331 (Claude Code)",
 "model": "claude-opus-5-5", "graphify_version": "graphify 0.9.92",
 "fixture_hash": "<40 hex>", "runs": 5,
 "cases": [{"case": "read-order", "arm": "main", "model": "claude-opus-5-5",
            "count": 5, "errored": 0, "runs": 5, "rule": "at-least", "threshold": 4,
            "result": "PASS"}]}
```

`result` is `PASS`, `FAIL` or `ERRORED`. `ERRORED` when `errored >= 1`. `arm` is `main` (no model column) or `ab` (model column given). Top-level `model` is the model of the `main` arm.

**`tests/behavior/evals/suite.conf`.** One line per case: `<case> <rule> <count>`. `#` starts a comment line. Blank lines are skipped.

**Arms row.** `<case> <base> <cand> <rule> <count> [<model>]`. The sixth column pins the model of the candidate arm. An arm key is `<sha>` without a model and `<sha>@<model>` with one.

**`warden_suite.py`** (in `plugins/warden/scripts/`):
- `parse_cli_version(raw: str) -> str | None`: the first `\d+\.\d+\.\d+` in `raw`.
- `minor(version: str | None) -> str | None`: `"2.1.331"` gives `"2.1"`.
- `read_suite_cases(conf_path: str) -> list[str]`: the case names of `suite.conf`, in file order.
- `load_summaries(folder: str) -> tuple[list[dict], list[str]]`: parsed summaries oldest first (by `date`, then file name), and the paths that do not parse or lack `schema`, `id`, `date`, `sha`, `cli_version`, `model` or `cases`.
- `combined_view(summaries: list[dict]) -> dict[str, dict]`: case name to `{"result", "count", "runs", "errored", "id"}`. It uses `arm == "main"` entries only. For each case it takes the newest non-`ERRORED` entry. If all are `ERRORED`, it takes the newest `ERRORED` entry.
- `group(summaries, key) -> list[tuple[tuple, list[dict]]]`: groups by `key(summary)`, ordered by the date of each group's newest summary, oldest first.
- `full_pins(s) -> tuple`: `(s["cli_version"], s["model"])`.
- `minor_pins(s) -> tuple`: `(minor(s["cli_version"]), s["model"])`.
- `is_covered_view(view, cases) -> bool`: every case in `cases` is in `view` with a result other than `ERRORED`.
- `newest_covered(summaries, cases) -> tuple[tuple, list[dict]] | None`: the newest minor-pins group whose combined view is covered.
- `is_covered(summaries, cases, model, cli_minor) -> bool`: the minor-pins group `(cli_minor, model)` is covered. When `cli_minor` is `None`, any group with that model that is covered counts.

**`warden_pins.py`** (in `plugins/warden/scripts/`):
- `cli_version(claude_path: str | None, timeout: int = 10) -> tuple[str | None, str | None, str | None]`: `(version, raw first line, error)`. With no path: `(None, None, "claude not found at schedule install")`. On a failure, a timeout or no version number: `(None, raw or None, "claude --version failed: <reason>")`.
- `session_model(projects_dir: str, since: datetime.datetime) -> tuple[str | None, int]`: the most common model among the main-session lines with a `timestamp` at or after `since`, and the count of those lines. A tie goes to the model of the newest tied line. `since` is timezone-aware.
- `settings_model(settings_path: str) -> str`: the `model` key when it starts with `claude-` and contains a digit, otherwise `"unknown"`.
- `current_pins(claude_path, projects_dir, settings_path, since) -> dict`: keys `cli_version`, `cli_version_raw`, `cli_error`, `model`, `model_source` (`logs`, `settings` or `unknown`), `model_lines`.

A main-session line: a JSON line with `type == "assistant"`, in a `.jsonl` file whose path has no `subagents` folder part, with `isSidechain` not `true`, and with `message.model` a non-empty string other than `<synthetic>`.

---

## Task 1: Per-arm model in the wrapper and the recorder, test-first

**Satisfies:** REQ-2, REQ-9

**Files:**
- Modify: `tests/behavior/run-behavior` (arms parsing near lines 70-82, the arm loop at lines 108-215)
- Modify: `tests/behavior/lib/record.py` (conf parsing near lines 180-186, the arm loop at lines 200-248, `trace_models` at line 119, the Results table near line 280)
- Modify: `tests/behavior/stubs/claude` (the trace writer)
- Test: `tests/behavior/tests/runner.sh`, `tests/behavior/tests/record_grading.sh`

**Depends on:** none

**Model:** sonnet (standard tier). The task crosses files.

**Interfaces:**
- Produces: the arms row `<case> <base> <cand> <rule> <count> [<model>]`. The sixth column pins the model of the candidate arm. The arm key is `<sha>` or `<sha>@<model>`. The recorder takes `--result <arm key>=<path>`. Traces are cached under `<raw>/<id>/traces/<case>/<sha7>` or `<sha7>-<model>`.
- Produces: `record.py` function `trace_models(raw_dir, case=None, arm_dir=None) -> set[str]`. With no `case` and `arm_dir`, it behaves exactly as today.

**Brief:** Today the wrapper builds each distinct SHA once, and one `--model` applies to every arm. This task makes the unit an arm: one commit plus an optional model. A row with a sixth column runs its candidate arm with `--model <that ID>`. Two rows for one case on one commit, one with a model and one without, give two result sets, two trace folders and two Results rows. When two arms on one commit differ in model, the Results table gets a `model` column. When they do not, the table is byte-identical to today. Five-column rows and the global `--model` flag work as today. The global `--model` applies to an arm without a sixth column.

The stub `claude` writes `--model` into `message.model` of its traces, and it falls back to `claude-stub-1`. The test needs this to see which arm ran which model.

Tests to write first. Commit them while they fail (REQ-9.4):
- T12 (`runner.sh`): an arms file with `case - HEAD at-least 4 claude-x-1` runs one eval whose `CALL eval` line in the stub log holds `--model claude-x-1`.
- T13 (`runner.sh`): an arms file with two `read-order` rows on `HEAD`, one without a model and one with `claude-x-1`, runs two evals. One has no `--model`, and one has `--model claude-x-1`. The record has two `read-order` rows and a `model` column that names `claude-stub-1` and `claude-x-1`.
- T14 (`runner.sh`): the existing five-column tests pass unchanged. No new assertion is needed. Rerun them and confirm.
- Golden (`record_grading.sh`): the existing regrades of `726866` and `cbb2f3` pass unchanged. Add one assertion: a five-column conf gives a Results header exactly `| case | arm | SHA | count/runs | criterion | result |`.

Test command: `bash tests/behavior_harness.sh runner && bash tests/behavior_harness.sh record_grading`.

**Steps:**
- [ ] Write T12 and T13 in `runner.sh` and the header assertion in `record_grading.sh`.
- [ ] Run `bash tests/behavior_harness.sh runner` and see T12 and T13 fail.
- [ ] Commit the failing tests: `test: per-arm model in the arms file (failing)`.
- [ ] Change the stub `claude` to write the `--model` value into its trace lines.
- [ ] Change the wrapper: parse the optional sixth column, iterate over distinct arm keys instead of SHAs, pass `--model` per arm, copy traces to the per-arm folder, and pass `--result <arm key>=<path>`.
- [ ] Change the recorder: accept five- or six-column conf rows, look results up by arm key, read the models per arm folder, and add the `model` column only when two arms on one commit differ in model.
- [ ] Run both test files and see them pass, including the golden regrades.
- [ ] Run `bash tests/run.sh` and see it pass.
- [ ] Commit: `feat: run one arm per commit and model in run-behavior`.

## Task 2: The summary reader, the combined view and coverage

**Satisfies:** REQ-3, REQ-5

**Files:**
- Create: `plugins/warden/scripts/warden_suite.py`
- Test: `tests/warden_suite.sh` (new; `tests/run.sh` picks it up by the `*_*.sh` glob)

**Depends on:** none

**Model:** sonnet (cheap tier). One production file, and the behaviour and tests are stated here.

**Interfaces:**
- Produces: every `warden_suite.py` function in the Shared interfaces section, with those exact names, parameters and return types.
- Consumes: the summary file format in the Shared interfaces section.

**Brief:** This module is the one place that knows how summaries group and combine. The weekly run (Task 6) and the comparison (Task 5) both load it. It does no I/O except reading the summary folder and `suite.conf`. It prints nothing. It never writes a file.

Tests (each writes hand-made summary files to a temp folder and calls the module through `python3 -I -c` with `sys.path` set to the scripts folder):
- `parse_cli_version("2.1.331 (Claude Code)")` gives `2.1.331`. `parse_cli_version("garbage")` gives `None`. `minor("2.1.331")` gives `2.1`.
- `read_suite_cases` skips comments and blank lines and keeps the file order.
- `load_summaries` returns the summaries oldest first, and it lists a file with bad JSON and a file without `cases` as unreadable.
- `combined_view`: a full run with `read-order` `ERRORED`, plus a newer `--case read-order` rerun with `PASS`, gives `PASS` with the rerun's `id`. (Basis for T18 and T37.)
- `combined_view` ignores `ab` entries.
- `combined_view` keeps `ERRORED` when every entry for a case is `ERRORED`.
- `is_covered` is false for a single-case summary when `suite.conf` lists five cases. (Basis for T36.)
- `is_covered` is true for a full run plus a rerun of its errored case. (Basis for T37.)
- `is_covered` ignores a patch difference: summaries on `2.1.331` cover current `2.1.340`.
- `newest_covered` skips a newer group that has an `ERRORED` case and returns the older covered group. (Basis for T52.)
- `is_covered` with `cli_minor=None` is true when a covered group has the same model. (Basis for T51.)

Test command: `bash tests/warden_suite.sh`.

**Steps:**
- [ ] Write `tests/warden_suite.sh` with the tests above.
- [ ] Run it and see it fail, because the module does not exist.
- [ ] Write `warden_suite.py` with the functions of the Shared interfaces section.
- [ ] Run the test and see it pass.
- [ ] Run `bash tests/run.sh` and see it pass.
- [ ] Commit: `feat: add the suite summary reader and coverage`.

## Task 3: Read the current pins without a model call

**Satisfies:** REQ-4

**Files:**
- Create: `plugins/warden/scripts/warden_pins.py`
- Test: `tests/warden_pins.sh` (new)

**Depends on:** none

**Model:** sonnet (cheap tier). One production file, and the behaviour and tests are stated here.

**Interfaces:**
- Produces: every `warden_pins.py` function in the Shared interfaces section, with those exact names, parameters and return types. The definition of a main-session line is there too.

**Brief:** This module reads the CLI version from the stored `claude` path, and the model from the transcripts under a projects folder. It keeps nothing from a transcript except the model ID and a line count (REQ-4.7). It never writes a file. Transcript timestamps are UTC ISO strings with a `Z`, such as `2026-11-27T10:00:00.000Z`. Compare them as aware datetimes. Skip a file whose mtime is older than `since`, before you open it. Skip a line that does not parse.

`cli_version` runs `[claude_path, "--version"]` with `timeout`, stdout captured, stderr discarded. A non-zero exit, a timeout, an `OSError` or no version number in the first line gives the error form.

`current_pins` uses `session_model` first. When it returns 0 lines, it uses `settings_model` and sets `model_source` to `settings`, or to `unknown` when that returns `unknown`.

Tests (synthetic transcripts in a temp `projects/` tree, and a stub `claude` script that the test writes):
- T24: lines in `p/<session>/subagents/agent-x.jsonl` with model `claude-sonnet-5-5` do not count.
- T25: a line with `isSidechain: true` does not count.
- T26: 40 lines of `claude-opus-5-5` and 3 lines of `claude-fable-5-2` give `claude-opus-5-5` and 43 lines.
- T27: a 2-2 tie gives the model of the newest line.
- A line before `since` does not count. A file with an old mtime is not read.
- T28: an empty window with `settings.json` `{"model": "claude-opus-5-5"}` gives `model_source` `settings`.
- T29: `{"model": "opus"}` gives `unknown`, and a missing key gives `unknown`.
- `<synthetic>` does not count.
- `cli_version` with a stub that prints `2.1.331 (Claude Code)` gives `("2.1.331", "2.1.331 (Claude Code)", None)`.
- `cli_version` with a stub that exits 1 gives an error that starts with `claude --version failed:`.
- `cli_version(None)` gives the error `claude not found at schedule install`.

Test command: `bash tests/warden_pins.sh`.

**Steps:**
- [ ] Write `tests/warden_pins.sh` with the tests above.
- [ ] Run it and see it fail, because the module does not exist.
- [ ] Write `warden_pins.py`.
- [ ] Run the test and see it pass.
- [ ] Run `bash tests/run.sh` and see it pass.
- [ ] Commit: `feat: read the current CLI version and model without a model call`.

## Task 4: Suite mode in the wrapper and the summary in the recorder

**Satisfies:** REQ-1, REQ-6, REQ-7

**Files:**
- Modify: `tests/behavior/run-behavior` (argument parsing at lines 17-29, a suite block before the preflight at line 44, the arms resolution at lines 70-82)
- Modify: `tests/behavior/lib/record.py` (a `--summary` flag, and the summary write after the Markdown write near line 296)
- Create: `tests/behavior/evals/suite.conf`
- Modify: `.gitignore` (add `__pycache__/`)
- Modify: `tests/behavior/README.md` (a "Suite mode" section and the sixth column)
- Test: `tests/behavior/tests/runner.sh`, `tests/behavior/tests/record_grading.sh`

**Depends on:** Task 1

**Model:** sonnet (standard tier). The task crosses files.

**Interfaces:**
- Consumes: the six-column arms row and the arm keys from Task 1.
- Produces: `run-behavior --suite [--case NAME] [--runs N] [--ab-model ID] [--record-dir DIR] [--yes]`.
- Produces: `record.py --summary`, which writes the summary file of the Shared interfaces section.
- Produces: `tests/behavior/evals/suite.conf` with exactly these lines:
  ```
  setup-planning at-least 4
  setup-quick-question at-most 1
  setup-non-coding at-most 1
  read-order at-least 4
  read-order-heldout at-least 4
  ```
- Exact messages, each followed by exit 2:
  - `suite runs only on main (current: <branch>)`
  - `suite needs a clean checkout: <path>`
  - `no suite criterion for <case>`
  - `no eval directory for <case>`
- Exact warning, without an exit: `warning: main is <N> commits behind fork/main (last fetch)`

**Brief:** `--suite` turns the wrapper into the suite run. Before the preflight, it makes the checks in this order:
1. The branch of `$REPO` is `main`.
2. `git -C "$REPO" status --porcelain -- plugins tests/behavior` is empty. Otherwise the message names the first path.
3. Every eval directory except `_fixture` has a `suite.conf` line, and every line has a directory.

Then it counts `git rev-list --count main..refs/remotes/fork/main`. If the count is above 0, it prints the warning. It never fetches. A missing `fork/main` prints no warning.

Suite mode writes its own arms file into `$WORK`. It holds one row `<case> - <HEAD sha> <rule> <count>` per case. With `--ab-model ID`, it adds a second row with `ID` in the sixth column. `--case` keeps one case. The default record folder in suite mode is `$WARDEN_LESSON_ROOT/suite`, or `~/.claude/lessons/suite`. `--record-dir` and `WARDEN_BEHAVIOR_RECORD_DIR` keep their precedence. The cost estimate, the prompt, the setup status stub and the graders run unchanged. Suite mode passes `--summary` to the recorder. Suite mode never deletes a file in the record folder.

`--summary` writes the summary through a `.tmp` file and `os.replace`, after the Markdown record. It takes `cli_version_raw` from the result's `claudeVersion`, `cli_version` through `parse_cli_version` (copy the regex `\d+\.\d+\.\d+`, because `record.py` must not import from `plugins/`), the per-arm models from Task 1's `trace_models`, and `errored` from the existing count. The recorder writes no summary when it returns 2 before the Markdown write, and none without `--summary`.

Add `__pycache__/` to `.gitignore`. `record.py` imports `graph_first.py`, so a run leaves `tests/behavior/lib/__pycache__/`, and the clean-checkout check would refuse every later suite.

Tests in `runner.sh`. They need a checkout that the test controls. Build a temp repository: `git archive HEAD plugins tests/behavior .gitignore | tar -x`, then `git init -b main`, commit, and run the temp copy of `run-behavior`:
- T1: on branch `other`, exit 2 with `suite runs only on main (current: other)` and no eval. Run it once more without `graphify` on `PATH`: the message is the same, and the exit is 2, not 3 (REQ-1.4).
- T2: an edit to a file under `plugins/` gives exit 2 with `suite needs a clean checkout: plugins/` and that path.
- T3: an untracked `tests/behavior/x` gives exit 2 with the clean-checkout message.
- T4: an untracked `notes.txt` at the root runs the suite.
- T5: with `refs/remotes/fork/main` two commits ahead (made with `git commit-tree` and `git update-ref`), the output holds `warning: main is 2 commits behind fork/main (last fetch)` before `Start`, and the stub log has no `fetch`.
- T6: a new eval directory `evals/new-case` gives `no suite criterion for new-case`.
- T7: an extra `suite.conf` line `ghost at-least 1` gives `no eval directory for ghost`.
- T8: `read-order` and `read-order-heldout` run on the setup status stub, the setup cases run on the real script, and the record holds `Setup status of <sha> in read-order: stubbed (ready)`.
- T9: the record and the summary land in the record folder. A pre-existing file there is still present and unchanged afterwards.
- T10: `--case read-order` runs one eval.
- T11: `--ab-model claude-x-1` prints `Agents: 50 (5 cases, 10 arms x 5 runs)`. With `--runs 1`, it prints `Agents: 10`.

Tests in `record_grading.sh`:
- T41: `--summary` writes a summary with every field of the Shared interfaces section. `cli_version` is `2.1.305`, from the stub's version line.
- T42: an errored run gives `ERRORED` in the summary and `FAIL` in the Markdown row.
- T43: a run without `--summary` writes no `.json`.
- T44: a partial result (exit 2) writes no `.json`.

Test command: `bash tests/behavior_harness.sh runner && bash tests/behavior_harness.sh record_grading`.

**Steps:**
- [ ] Write T1 to T11 in `runner.sh`, with a helper that builds the temp checkout.
- [ ] Write T41 to T44 in `record_grading.sh`.
- [ ] Run both and see the new tests fail.
- [ ] Add `__pycache__/` to `.gitignore`.
- [ ] Add `suite.conf` with the five lines above.
- [ ] Add `--summary` to the recorder.
- [ ] Add `--suite`, `--ab-model` and the suite checks to the wrapper.
- [ ] Run both test files and see them pass.
- [ ] Add the "Suite mode" section and the sixth column to `tests/behavior/README.md`.
- [ ] Run `bash tests/run.sh` and see it pass.
- [ ] Commit: `feat: add suite mode to run-behavior and the suite summary`.

## Task 5: The comparison script

**Satisfies:** REQ-3

**Files:**
- Create: `tests/behavior/lib/suite_compare.py`
- Test: `tests/behavior/tests/suite_compare.sh` (new; `tests/behavior_harness.sh` picks it up by its glob)

**Depends on:** Task 2

**Model:** sonnet (cheap tier). One production file, and the behaviour and tests are stated here.

**Interfaces:**
- Consumes: `warden_suite.load_summaries`, `combined_view`, `group` and `full_pins` from Task 2. The script loads `<repo>/plugins/warden/scripts/warden_suite.py` with `importlib.util.spec_from_file_location`, where `<repo>` is two folders above the script's own folder.
- Consumes: the summary file format.
- Produces: `python3 -I suite_compare.py --folder DIR --new ID --repo REPO`. It prints the comparison to stdout and always exits 0, except 2 for a usage error or when `--new` is missing.
- Exact strings:
  - `plugin files: changed between <old7> and <new7>`
  - `plugin files: unchanged`
  - `plugin files: unknown (<old7> not found)`
  - `FLIPPED`
  - `not comparable (<N> errored)`
  - `rerun: warden-lesson suite --case <case>`
  - `new case`
  - `not in old record`
  - `no earlier suite record with different pins`
  - `skipped unreadable summary: <file>` (stderr)

**Brief:** The script takes the new summary's full pins group as the new side, and the newest earlier group with different full pins as the old side. It computes the combined view of each side. The header names each side's summary IDs, short SHAs, CLI versions and models. The plugin-files line uses `git -C REPO diff --quiet <old> <new> -- plugins/`: exit 0 is unchanged, exit 1 is changed. If `git cat-file -e <old>^{commit}` fails, the line reads unknown. The old side's SHA is the SHA of its newest summary, and so is the new side's.

Each row shows `case`, the old count/runs and result, the new count/runs and result, and the source summary ID of each side. A row shows `FLIPPED` only for `PASS` against `FAIL`. With `ERRORED` on either side, the row shows `not comparable (<N> errored)` and the rerun hint, where N is the errored count of the `ERRORED` side. With no earlier group, the script prints `no earlier suite record with different pins` and the newest same-pins summary ID when one exists.

When the new summary has `ab` entries, a second block headed `A/B: <ab model> against <main model>` compares the `ab` and `main` entries of that summary by the same row rules.

Tests (hand-written summaries, a temp git repository with two commits for the plugin-files line):
- T15: old `PASS`, new `FAIL` gives a row with `FLIPPED`.
- T16: old 5/5 `PASS`, new 4/5 `PASS` gives no `FLIPPED`.
- T17: new `ERRORED` with 2 errored gives `not comparable (2 errored)` and `rerun: warden-lesson suite --case read-order`, and no `FLIPPED`.
- T18: a full run with `read-order` `ERRORED` and a newer rerun with `PASS`, both on the new pins, give a `PASS` row that names the rerun's ID.
- T19: two commits with a change under `plugins/` give `changed between`. Two commits with a change outside `plugins/` give `unchanged`.
- T20: an old SHA that is not in the repository gives `unknown (`.
- T21: a single summary gives `no earlier suite record with different pins`.
- T22: a folder with a broken `.json` prints `skipped unreadable summary:` on stderr and still compares the good ones.
- T23: a summary with `ab` entries prints the `A/B:` block, with `FLIPPED` where `ab` fails and `main` passes.

Test command: `bash tests/behavior_harness.sh suite_compare`.

**Steps:**
- [ ] Write `tests/behavior/tests/suite_compare.sh` with T15 to T23.
- [ ] Run it and see it fail, because the script does not exist.
- [ ] Write `suite_compare.py`.
- [ ] Run the test and see it pass.
- [ ] Run `bash tests/behavior_harness.sh` and see it pass.
- [ ] Commit: `feat: add the suite comparison`.

## Task 6: Version check in the weekly run, status and schedule install

**Satisfies:** REQ-4, REQ-5, REQ-7, REQ-8

**Files:**
- Modify: `plugins/warden/scripts/warden_ledger.py` (`weekly_cmd` at line 384, `_weekly_line` at line 429, `_install` at line 484, `_schedule_line` at line 601, `status_lines` at line 622, `PLIST_TEMPLATE` at line 316)
- Test: `tests/warden_ledger.sh`

**Depends on:** Task 2, Task 3

**Model:** sonnet (standard tier). One production file, but the task consumes two modules and changes three existing behaviours.

**Interfaces:**
- Consumes: `warden_pins.current_pins(claude_path, projects_dir, settings_path, since)` and `warden_suite.load_summaries`, `read_suite_cases`, `minor`, `is_covered`, `newest_covered` and `minor_pins`. Load both modules by path from the folder of the ledger module, the same way `warden-lesson` loads `warden_ledger.py` in `_ledger()`.
- Test seams (environment variables, read only by this task's code):
  - `WARDEN_CLAUDE`: the stored `claude` path. Launchd sets it from the plist.
  - `WARDEN_PROJECTS_DIR`: default `~/.claude/projects`.
  - `WARDEN_SETTINGS`: default `~/.claude/settings.json`.
  - `WARDEN_SUITE_CONF`: default `<checkout>/tests/behavior/evals/suite.conf`. `<checkout>` is three folders above the ledger module's real path.
- The suite folder is `<inbox>/suite`.
- Exact notification lines (appended after the ledger text, one notification in total):
  - `No complete suite record yet. Run: warden-lesson suite`
  - `Model changed: <old> → <new>. Run: warden-lesson suite`
  - `Claude Code <old X.Y> → <new X.Y>. Run: warden-lesson suite`
- Exact status lines:
  - `suite: last run <YYYY-MM-DD> on <CLI version>, <model>. Now <CLI version>, <model> (<source>)`
  - `suite: never run`
  - `version check: claude not found at schedule install`
- Exact install line: `claude not found; the version check is off`
- New `last-run` keys: `cli_version`, `model`, `model_source`, `model_lines`, plus `cli_error` when the CLI check failed.

**Brief:** The weekly run reads the current pins after the ledger view. The log window starts at the `ts` of the previous `last-run`, converted to an aware datetime with `astimezone()`. Without a previous run, it starts 7 days before `now()`. Coverage uses the CLI minor and the model. A `cli_error` sets the CLI minor to `None`, so coverage depends on the model alone (REQ-5.12). The `cli_error` also goes into the `error` field of `last-run`. An `unknown` model sends no version line.

The version lines are built this way:
1. No covered group: the `No complete suite record yet` line.
2. Not covered, with a newest covered group: a model line when the model differs, and a Claude Code line when the CLI minor differs. The old values come from the newest covered group (ruling F2).

The weekly run sends one notification when the ledger text or a version line exists. The message is the current ledger message, then the version lines, then the report path. With no ledger hits, the ledger counts line is left out. When neither exists, there is no notification. The report file gets one more line: `pins: <cli> <model> (<source>), unchanged since the last weekly run` or `pins: changed since the last weekly run (<old cli> <old model> → <new cli> <new model>)`. This line includes patch-only changes.

`schedule install` adds `EnvironmentVariables: {"WARDEN_CLAUDE": <shutil.which("claude")>}` to the plist. It keeps the `which` path exactly and calls no `realpath`. When `which` returns `None`, the install leaves the key out, prints `claude not found; the version check is off`, and goes on.

`status_lines()` returns the existing two lines, then the suite line, then the warning line when the plist exists without `WARDEN_CLAUDE`. The suite line reads the newest summary and the `last-run` pins. Without a `last-run` that has pins, the `Now` part reads `Now unknown`.

Tests in `tests/warden_ledger.sh` (stub `claude` and stub `osascript` on `PATH`, `WARDEN_NOW` for time, a temp projects tree, hand-written summaries, a temp `suite.conf` with two cases):
- T30: after a weekly run over transcripts that hold the text `SECRET-PROMPT`, no file under the inbox contains `SECRET-PROMPT`.
- T31: an empty suite folder gives one notification with `No complete suite record yet`.
- T32: covered summaries on `claude-opus-5-5` and transcripts on `claude-opus-6-0` give `Model changed: claude-opus-5-5 → claude-opus-6-0`.
- T33: a second weekly run a week later, with nothing changed, notifies again.
- T34: covered on `2.1.x` and the stub on `2.2.0` give `Claude Code 2.1 → 2.2`.
- T35: covered on `2.1.331` and the stub on `2.1.340` give no notification.
- T36: a single-case summary on the new pins alone still notifies.
- T37: a full run with one `ERRORED` case plus a rerun of that case on the new pins gives no notification.
- T38: a stub `claude` that exits 1 records the error in `last-run`, and `model` is still set.
- T39: a recurring ledger entry and a model change give one `osascript` call that holds both texts.
- T40: no ledger hits and covered pins give no `osascript` call.
- T45: `last-run` holds `cli_version`, `model`, `model_source` and `model_lines`.
- T46: `schedule install` with `claude` on `PATH` as a symlink stores the symlink path, not its target.
- T47: `schedule install` without `claude` exits 0 and prints `claude not found; the version check is off`.
- T48: `status` prints the suite line with the newest summary's date and pins.
- T49: `status` with no summary prints `suite: never run`.
- T50: `status` with a plist without `WARDEN_CLAUDE` prints the warning line.
- T51: a stub `claude` that exits 1 and a covered model give no version line.
- T52: a newer summary with an `ERRORED` case on `claude-opus-6-0`, an older covered group on `claude-opus-5-5`, and current `claude-opus-6-0` give `Model changed: claude-opus-5-5 → claude-opus-6-0`.
- The existing weekly, schedule and status tests pass unchanged.

Test command: `bash tests/warden_ledger.sh`.

**Steps:**
- [ ] Write T30 to T52 in `tests/warden_ledger.sh`.
- [ ] Run it and see the new tests fail.
- [ ] Add the pins read, the coverage check and the version lines to `weekly_cmd`.
- [ ] Add the pins line to the report file.
- [ ] Add `WARDEN_CLAUDE` to the plist in `_install`.
- [ ] Add the suite line and the warning line to `status_lines`.
- [ ] Run the test and see it pass.
- [ ] Run `bash tests/run.sh` and see it pass.
- [ ] Commit: `feat: detect model and CLI changes in the weekly run`.

## Task 7: The `suite` subcommand and the comparison after a suite run

**Satisfies:** REQ-1, REQ-3, REQ-8

**Files:**
- Modify: `plugins/warden/scripts/warden-lesson` (`main` at line 1133)
- Modify: `tests/behavior/run-behavior` (after the recorder call near line 220)
- Modify: `README.md` (the `warden-lesson` command list and the status lines)
- Test: `tests/warden_lessons.sh`, `tests/behavior/tests/runner.sh`

**Depends on:** Task 4, Task 5

**Model:** sonnet (standard tier). The task crosses files.

**Interfaces:**
- Consumes: `run-behavior --suite [--case NAME] [--runs N] [--ab-model ID]` from Task 4.
- Consumes: `suite_compare.py --folder DIR --new ID --repo REPO` from Task 5.
- Produces: `warden-lesson suite [--case NAME] [--runs N] [--ab-model ID]`.

**Brief:** `warden-lesson suite` finds `run-behavior` at `<checkout>/tests/behavior/run-behavior`, where `<checkout>` is three folders above the real path of the lesson script. It runs that file with `--suite` and the given flags. The wrapper inherits stdin, so the `[y/N]` prompt works. `warden-lesson suite` returns the wrapper's exit code. When the wrapper file is missing, it prints `suite: run-behavior not found at <path>` and exits 2.

In suite mode, after the recorder returns 0 or 1, the wrapper runs `suite_compare.py` with the record folder, the run ID and `$REPO`. Then it exits with the recorder's code. A comparison failure prints a warning and keeps the recorder's code (REQ-1.16).

Tests:
- `tests/warden_lessons.sh`: `warden-lesson suite --case read-order --runs 1` runs a stub `run-behavior` placed at the checkout path, and that stub logs `--suite --case read-order --runs 1`. The exit code of the stub passes through.
- `tests/warden_lessons.sh`: with no `run-behavior` at the path, the command exits 2 with the message.
- `runner.sh`: two suite runs in the temp checkout, the second with `STUB_TRIG` set so `read-order` fails, and with the stub version line set to a different version (add a `STUB_CLAUDE_VERSION` override to the stub). The second run prints a `read-order` row with `FLIPPED`. The exit code is the recorder's exit code.

Test command: `bash tests/warden_lessons.sh && bash tests/behavior_harness.sh runner`.

**Steps:**
- [ ] Write the three tests.
- [ ] Run them and see them fail.
- [ ] Add the `suite` subparser and its function to `warden-lesson`.
- [ ] Add the `STUB_CLAUDE_VERSION` override to `tests/behavior/stubs/claude`.
- [ ] Add the comparison call to the wrapper's suite mode.
- [ ] Run the tests and see them pass.
- [ ] Add `warden-lesson suite` and the new status lines to `README.md`.
- [ ] Run `bash tests/run.sh` and `bash tests/behavior_harness.sh`, and see both pass.
- [ ] Commit: `feat: add warden-lesson suite`.

Note: Task 7 also edits `tests/behavior/stubs/claude`, which Task 1 owns. Task 1 is two waves earlier, so they do not conflict.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2, 3 | Each task owns different files and has no dependency. |
| 2 | 4, 5, 6 | Task 4 needs Task 1, Task 5 needs Task 2, and Task 6 needs Tasks 2 and 3. They own different files. |
| 3 | 7 | It needs Task 4 and Task 5, and it edits `run-behavior` after Task 4. |

Files per wave:
- Wave 1: Task 1 owns `run-behavior`, `record.py`, `stubs/claude`, `runner.sh` and `record_grading.sh`. Task 2 owns `warden_suite.py` and `tests/warden_suite.sh`. Task 3 owns `warden_pins.py` and `tests/warden_pins.sh`.
- Wave 2: Task 4 owns `run-behavior`, `record.py`, `suite.conf`, `.gitignore`, `tests/behavior/README.md`, `runner.sh` and `record_grading.sh`. Task 5 owns `suite_compare.py` and `tests/behavior/tests/suite_compare.sh`. Task 6 owns `warden_ledger.py` and `tests/warden_ledger.sh`.
- Wave 3: Task 7 owns `warden-lesson`, `run-behavior`, `stubs/claude`, `README.md`, `tests/warden_lessons.sh` and `runner.sh`.

After the last wave: the final review, the fix wave and the scoped re-review, then `reconciling-specs`.

## Requirement coverage

| Requirement | Task |
|---|---|
| REQ-1 suite run | 4, 7 |
| REQ-2 per-arm model | 1 |
| REQ-3 comparison | 2, 5, 7 |
| REQ-4 current pins | 3, 6 |
| REQ-5 weekly notification | 2, 6 |
| REQ-6 summary | 4 |
| REQ-7 suite folder and last-run | 4, 6 |
| REQ-8 interface | 6, 7 |
| REQ-9 offline tests | 1, and every task's test command |

## Risks, worst first

1. **Task 1 can change how existing records grade.** The arm loop changes from SHA keys to arm keys in both the wrapper and the recorder. The trace cache folder changes too. A slip in the five-column path changes the committed records' regrade. The golden tests and the unchanged-header assertion catch this. Task 1 carries the most risk.
2. **The clean-checkout guard can refuse every suite.** `record.py` leaves `tests/behavior/lib/__pycache__/` behind, and `.gitignore` does not list it today. Task 4 adds `__pycache__/` to `.gitignore`, and T9 runs two suites in a row in one checkout.
3. **False version alarms train Nicolai to ignore the notification.** The causes are a timezone slip in the log window, subagent lines that count, or an alias in `settings.json`. T24 to T29 and T35 cover them. The window conversion uses `astimezone()` on the naive local `ts` that `now()` writes.
4. **Ledger notifications can regress.** Task 6 rebuilds the message in `weekly_cmd`. The existing T18 and the quiet-week test in `tests/warden_ledger.sh` stay unchanged and must pass.
5. **The live plist has no `WARDEN_CLAUDE` until a new install.** After the merge, `status` prints `version check: claude not found at schedule install` until Nicolai runs `warden-lesson schedule install` again. The hand-over lists that command next to the first suite run.
6. **The suite runs the wrapper of the checkout, not of the worktree.** `warden-lesson` resolves its own real path, and `~/.claude/bin` points at `~/Warden_public`. The suite therefore always runs on `main` there, which is the intent. A run from this worktree is refused by the branch check.

Ruled out:
- Reading the CLI version from the transcripts' `version` field. The spec makes `claude --version` the source (Non-goals).
- Parsing the Markdown records for the comparison. Approach A1 chose JSON summaries.
- Two wrapper calls for `--ab-model`. Approach A3 was rejected because it gives two prompts.
- Importing `warden_suite.py` from `record.py`. The recorder copies the one version regex, so the recorder does not depend on `plugins/` at a different commit.
