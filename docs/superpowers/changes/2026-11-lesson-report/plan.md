# Lesson Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `warden-lesson report` groups the inbox failures by normalized signature across sessions and repos, flags the repeats and hides the noise, and Node failures get their `Error:` line as the signature.

**Architecture:** Both changes live in the one stdlib script `plugins/warden/scripts/warden-lesson`, which is the existing pattern. A pure function `report_rows` builds the grouped rows from the inbox. A thin `_report` subcommand prints them. The capture fix is one skip rule inside `_pick_error_line`.

**Tech Stack:** Python 3 stdlib, bash tests in the `tests/lib/harness.sh` style.

**Spec:** `docs/superpowers/changes/2026-11-lesson-report/intent.md` (bounded change, no spec).

## Global Constraints

- `report` is read-only. It writes no file, and it does not call `retention()`.
- The inbox format does not change. `list`, `status`, `add` and `hook` output does not change, except for the Node signature fix.
- The normalized signature is the signature with every digit run replaced by `N`: `re.sub(r"\d+", "N", sig)`. This is the rule `_session_records` already uses at `warden-lesson:566`.
- A session is one file in `<inbox>/sessions/`. Its key is the file name without `.jsonl`.
- Flagged: the signature occurs in 2 or more distinct non-empty repos, or in 3 or more sessions.
- A fixed test failure is a session record with `fixed` true and `edits` > 0. A record with `fixed` true and `edits` == 0 is flaky.
- Hidden reasons, exact strings: `fixed test failure`, `one-off exception`, `no signature`.
- A hide rule other than `no signature` applies only when the signature occurs in exactly 1 session.
- Exception signature: matches `^(?:[\w.]+\.)?\w+(?:Error|Exception):`. Bare `Error:` and `error:` do not match, because tools print them. Environment classes stay visible: `ModuleNotFoundError`, `ImportError`, `FileNotFoundError`, `PermissionError`, `ConnectionRefusedError`, `TimeoutError`, `OSError` (the last five added after the final review, finding F4).
- Run Python as `python3 -I`. Write no `__pycache__`.
- No committed file holds a machine path.

---

### Task 1: Skip `node:internal` stack-frame lines when choosing the signature

**Files:**
- Modify: `plugins/warden/scripts/warden-lesson:394-407` (`_pick_error_line`)
- Test: `tests/warden_lessons.sh` (new block after the Q-series signature tests, near line 600)

**Depends on:** none

**Model:** `sonnet`. Files, behaviour and tests are all stated here, and the task touches one production file.

**Brief:** Node prints a crash as `node:internal/modules/cjs/loader:1228`, then `  throw err;`, then `  ^`, then a blank line, then `Error: Cannot find module '/x/y.js'`. The command name `node` is in the strict prefix set, so `node:internal/...` matches `<name>:` and wins. The inbox shows the result as `node:internal<path>:2111`. Vitest shows the same shape. The fix: in `_pick_error_line`, skip any stripped line that starts with `node:internal/` before every other check. Then the `Error:` line is chosen. No other line changes its result.

The test calls `wl.signature` through the `py` helper and asserts:
1. `signature("Exit code 1\nnode:internal/modules/cjs/loader:1228\n  throw err;\n  ^\n\nError: Cannot find module '/a/b.js'\n    at Module._resolveFilename (node:internal/modules/cjs/loader:1225:15)", "node b.js")` returns `"Error: Cannot find module '<path>'"`.
2. The same output under `npx vitest run` returns the same `Error:` line.
3. Output that holds only `node:internal/process/task_queues:95` and an indented `at` line under `node x.js` does not return a `node:internal` line. It returns the last-line fallback or `""`, and the result does not start with `node:internal`.
4. `signature("Exit code 1\nnode: bad option: --foo", "node --foo")` still returns `node: bad option: --foo`. This guards the `<name>:` rule.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Write the four assertions as one `py` block with a `pass`/`fail` line, in the style of the Q-series tests.
- [ ] Run `bash tests/warden_lessons.sh` and see the new block fail on assertion 1 with a `node:internal` result.
- [ ] Add the skip rule at the top of the loop in `_pick_error_line`: `if line.startswith("node:internal/"): continue`.
- [ ] Run `bash tests/warden_lessons.sh` and see every block pass.
- [ ] Commit: `fix: skip node:internal stack frames when choosing the lesson signature`.

---

### Task 2: Add `warden-lesson report`

**Files:**
- Modify: `plugins/warden/scripts/warden-lesson` (new helpers after `_all_records` at line 603, new `_report` after `_list`, new subparser in `main`)
- Test: `tests/warden_lessons.sh` (new block at the end, before `harness_exit`)

**Depends on:** Task 1 (same production file and same test file)

**Model:** `sonnet`. Files, behaviour and tests are all stated here, and the task touches one production file.

**Interfaces:**
- Produces: `report_rows(include_hidden=False) -> (rows, lessons, hidden_counts)`.
  - `rows`: list of dicts with keys `sig` (first signature seen, not normalized), `norm`, `sessions` (int), `repos` (sorted list of non-empty repo names), `count` (sum of the session record counts), `cmds` (sorted list of distinct `cmd` values), `last_ts`, `flagged` (bool), `flaky` (bool), `hidden` (`None` or one reason string).
  - `lessons`: the manual lesson records, newest first, with the keys `_all_records` already gives them.
  - `hidden_counts`: dict from reason string to number of hidden rows. It is the same whether `include_hidden` is true or false.
  - When `include_hidden` is false, `rows` holds no hidden row.

**Brief:** The report reads every session file through `_log_files()`, `_read_lines()` and `_session_records()`. It tags each session record with its session key (the file name stem). It does not change `_all_records` or `_session_records`, so `list --json` keeps its keys. Extract the digit normalization into `_norm(sig)` and use it in both `_session_records` and the report, so the two groupings cannot drift.

The report groups session records by `_norm(sig)`. Per group:
- `flagged` is true when `len(repos) >= 2` or `sessions >= 3`.
- `flaky` is true when any record in the group has `fixed` true and `edits == 0`.
- `hidden` is set in this order, first match wins:
  1. `no signature` when `sig` is empty.
  2. `fixed test failure` when `sessions == 1` and every record in the group has `fixed` true and `edits > 0`.
  3. `one-off exception` when `sessions == 1`, the signature matches the exception pattern from Global Constraints, and the class is not `ModuleNotFoundError` or `ImportError`.
- A flagged row is never hidden, except for `no signature`.

Row order: flagged rows first, then by `sessions` descending, then by `last_ts` descending.

Text output, one row per line, fields joined by two spaces:
`!!` or `--`, `s<sessions>`, `x<count>`, the repos joined by `,` (or `-`), the cmds joined by `,` (or `-`), the `sig` (or `-`), then `flaky` when set, then `hidden(<reason>)` when the row is hidden and `--all` was given.
Then a blank line and `Lessons:`, one line per manual lesson: date, `src`, repo or `-`, text. Omit the section when there is no lesson.
Then the last line: `hidden: N fixed test failure, N one-off exception, N no signature`. Print it in both modes. Print `hidden: 0` when nothing is hidden.

`report --all` passes `include_hidden=True`. `report` has no other option.

The test builds a synthetic inbox in a `fresh_root`, with lines written by `jfail`-style helpers that take the session file, the repo, `cmd`, `sig`, and an optional `h`. The `jfail` helper hard-codes `repo` to `r`, so add a variant with a repo argument rather than change `jfail`. Sessions `s1`, `s2`, `s3` have repo `alpha`. Session `s4` has repo `beta`. Contents:

| Signature | Where | Expected |
|---|---|---|
| `fatal: not a git repository` | s1, s4 | shown, flagged (2 repos) |
| `zsh:1: command not found: foo` | s1, s2, s3 | shown, flagged (3 sessions) |
| `make: *** [all] Error 2` | s2, three fails | shown, not flagged, count 3 |
| `KeyError: 'k'` | s1, s3 | shown, not flagged, not hidden |
| `AttributeError: 'list' object has no attribute 'keys'` | s2 | hidden `one-off exception` |
| `ModuleNotFoundError: No module named 'yaml'` | s2 | shown (environment class) |
| `FAILED tests/a.py::t` with `h`, an edit, a pass | s3 | hidden `fixed test failure` |
| `FAILED tests/b.py::t` with `h`, a pass, no edit | s4 | shown, `flaky` |
| empty signature | s4 | hidden `no signature` |
| manual lesson `remember the setup check` | `manual.jsonl` | in `lessons` |

The test asserts, through the `py` helper calling `wl.report_rows()`:
1. Exactly 2 rows are flagged, and they are the `fatal:` and `zsh:` rows.
2. The `make:` row has `count == 3`, `sessions == 1`, and is not flagged.
3. The default rows hold exactly these 6 signatures: `fatal:`, `zsh:`, `make:`, `KeyError`, `ModuleNotFoundError`, `FAILED tests/b.py::t`.
4. The `FAILED tests/b.py::t` row has `flaky` true.
5. `hidden_counts == {"fixed test failure": 1, "one-off exception": 1, "no signature": 1}`.
6. `report_rows(include_hidden=True)` returns 9 rows, and the 3 extra rows carry the expected reasons.
7. `lessons` holds 1 record with text `remember the setup check`.
8. The first two rows are the flagged rows.

The test also runs `WL report` and asserts:
9. The last line is `hidden: 1 fixed test failure, 1 one-off exception, 1 no signature`.
10. The output holds no `hidden(` marker, and `WL report --all` holds exactly 3.
11. The inbox is unchanged: a `find "$ROOT" -type f -exec shasum {} +` listing before and after `WL report` and `WL report --all` is identical.
12. `WL report` on an empty inbox prints `hidden: 0` and exits 0.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Add a repo-aware fail-line helper and write the synthetic inbox block with assertions 1 to 12.
- [ ] Run `bash tests/warden_lessons.sh` and see the block fail with `report_rows` not defined.
- [ ] Extract `_norm(sig)` and use it in `_session_records`.
- [ ] Run `bash tests/warden_lessons.sh` and see the existing L-series grouping tests still pass.
- [ ] Write `report_rows` with the grouping, flag, flaky and hide rules above.
- [ ] Write `_report` and register the `report` subparser with `--all` in `main`.
- [ ] Run `bash tests/warden_lessons.sh` and see every block pass.
- [ ] Run `bash tests/run.sh` and see the full suite pass.
- [ ] Run `python3 -I plugins/warden/scripts/warden-lesson report` on the real inbox and read the output for sense. Put the output in the task report.
- [ ] Commit: `feat: add warden-lesson report`.

---

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1 | It owns `warden-lesson` and `tests/warden_lessons.sh`. |
| 2 | 2 | It owns the same two files as Task 1. |

The work cannot run in parallel. Both tasks edit the same script and the same test file, and the script is a single file by design.

After the last wave: the final review, the fix wave and the scoped re-review. A bounded change has no spec, so there is no `reconciling-specs` step.

## Risks, worst first

1. **The hide rules hide a real repeat.** This is the worst failure, because a hidden row is invisible by default. The guard is the rule that every hide except `no signature` needs exactly 1 session, so any second sighting brings the row back. Assertion 3 covers the `KeyError` case. Task 2 carries the most risk.
2. **The exception pattern is too wide or too narrow.** Too wide: a tool error such as `Error: Invariant: …` from Next.js is hidden as project code. The pattern requires a class name before `Error`, so bare `Error:` stays visible. Too narrow: an unusual exception class stays visible. A visible extra row costs one line of reading, so the plan accepts the narrow side.
3. **The Node skip drops a useful line.** If the output holds only `node:internal` frames, the signature falls back to the last line or becomes empty. Assertion 3 of Task 1 covers this. An empty signature is hidden under `no signature`, so the row stays counted.
4. **`_norm` extraction changes `list` grouping.** The function is a pure move of one expression. The existing L-series tests run after the move, before any new code.
5. **The report writes to the inbox.** `report` never calls `write_line` or `retention()`. Assertion 11 checks the file hashes.

Ruled out:
- A `--json` flag for `report`. The tests call `report_rows` directly, and nobody reads the report by machine. YAGNI.
- Grouping by `(cmd, sig)`. The intent groups by signature alone, so the same error from `node` and `npx vitest` lands on one row.
- Recording traceback frames (option B). The intent keeps it as a later option.
- Splitting the script into modules. The file is 651 lines with one clear section per mode. A report section of about 80 lines does not justify a split.
