# Lessons Ledger and Weekly Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each failure class in the lesson inbox a recorded decision, show fixed classes that came back at the top of the report, and run the report every Monday with a notification only when something needs action.

**Architecture:** A new module `warden_ledger.py` sits beside `warden-lesson`. The lesson script loads it with `importlib` from its own real path, and only in the `mark`, `report`, `status`, `weekly` and `schedule` modes. The module reads the rows that `report_rows()` and `nudge_rows()` already build and tags them. It never groups rows again.

**Tech Stack:** Python 3 standard library only (the code must run on 3.9 and later), bash tests with `tests/lib/harness.sh`, launchd, `osascript`.

**Spec:** `docs/superpowers/changes/2026-11-lessons-ledger-weekly-report/spec.md` (approved, 737b294). Intent: `intent.md` in the same folder.

## Global Constraints

- The ledger is `<inbox>/ledger.jsonl`. `<inbox>` is what `inbox()` returns. Tests set `WARDEN_LESSON_ROOT`.
- Statuses: `open`, `fixed`, `verified`, `ignored`. Kinds: `sig`, `nudge`.
- Ledger line keys: `slug`, `kind`, `match` (sig only), `status`, `pr` (int or absent), `fixed_on` (`YYYY-MM-DD` or absent), `note`, `ts` (UTC, `YYYY-MM-DDTHH:MM:SSZ`, from `_now()`).
- The latest line per slug wins. "Latest" means the last line in the file for that slug.
- `mark` exits 2 on bad input and 1 on an OS error or when capture is disabled. It never writes a line on a refusal.
- Report, `weekly` and `status` never write the ledger, and never write the inbox outside `<inbox>/weekly/`.
- The weekly folder is `<inbox>/weekly/`. Files: `report-YYYY-MM-DD.txt` (keep the 12 newest), `last-run`, `schedule.json`, `launchd.err`.
- The schedule runs every Monday at 09:15. The launchd label is `com.warden.lesson-weekly`.
- The plist folder is `$WARDEN_LAUNCH_AGENTS`, default `~/Library/LaunchAgents`.
- `WARDEN_NOW` (local time, `YYYY-MM-DDTHH:MM:SS`) replaces the current time in `weekly` and `status` when it is set. Tests set it and set `TZ=Europe/Oslo`.
- The session day is the local date of the `ts` of the first line that parses in a session file, of any record type.
- An after-fix session has a session day later than the entry's `fixed_on`.
- The notification title is `Warden lessons`. The message holds counts and the report path, never signature text.
- No committed file holds a plist or a home path (`tests/no_machine_content.sh`).
- Model for every subagent task: `sonnet`.

---

## File Structure

| File | Responsibility |
|---|---|
| `plugins/warden/scripts/warden_ledger.py` (create) | Ledger read and write, `mark`, matching, the after-fix rule, the report decoration, `weekly`, the status lines, `schedule`. |
| `plugins/warden/scripts/warden-lesson` (modify) | The lazy loader, the new subparsers, the row and nudge session keys, `ignored` as a hide reason, the report printer split into a reusable function. |
| `bin/warden-lesson` (modify) | The comment line lists the new modes. |
| `tests/warden_ledger.sh` (create) | T1 to T26 and T18b. `tests/run.sh` picks it up through its `*_*.sh` glob. |
| `tests/stubs/osascript`, `tests/stubs/launchctl` (create) | PATH stubs that log their arguments to `$WARDEN_STUB_LOG`. |
| `docs/superpowers/changes/2026-11-lessons-ledger-weekly-report/seed.sh` (create) | The four seed `mark` calls for REQ-10. |
| `tests/warden_ledger_seed.sh` (create) | Runs `seed.sh` against a temporary inbox. |

---

### Task 1: The ledger store, the lazy loader and `mark` without match output

**Satisfies:** REQ-1, REQ-7, REQ-8

**Files:**
- Create: `plugins/warden/scripts/warden_ledger.py`
- Modify: `plugins/warden/scripts/warden-lesson` (module docstring "Modes:" line, `main()` at the end of the file)
- Create: `tests/warden_ledger.sh`

**Depends on:** none

**Model:** `sonnet` (standard tier). The task crosses two production files.

**Interfaces:**
- Produces, in `warden-lesson`: `_ledger()` returns the `warden_ledger` module. It loads the file `os.path.join(os.path.dirname(os.path.realpath(__file__)), "warden_ledger.py")` with `importlib.util.spec_from_file_location("warden_ledger", path)`, stores it in `sys.modules["warden_ledger"]`, and sets `module.WL = sys.modules[__name__]` before it returns. A second call returns the cached module.
- Produces, in `warden_ledger.py`:
  - `WL`: the lesson script module, set by `_ledger()`. The module calls `WL.inbox()`, `WL.write_line()`, `WL._fit()`, `WL._now()`, `WL._read_lines()`.
  - `STATUSES = ("open", "fixed", "verified", "ignored")`
  - `ledger_path() -> str`
  - `read_ledger() -> dict` with keys `entries` (slug to the latest line), `history` (slug to a list of lines, oldest first), `skipped` (slugs whose current `match` does not compile, sorted), `readable` (False when the file exists and `open` fails). A missing file gives empty dicts and `readable` True.
  - `mark_cmd(args) -> int`

**Brief:** Build the ledger file and the `mark` command, and keep the hook path free of the new module.

`mark` takes `slug` (optional, for `--list`), `status` (optional), `--match`, `--nudge`, `--pr` (int), `--fixed-on`, `--note`, `--history`, `--list`. The rules:
1. `mark --list` prints one line per current entry: slug, status, `#pr` if set, `fixed_on` if set, kind, note. Sorted by slug.
2. `mark <slug> --history` prints every line for the slug as JSON, oldest first. Exit 2 if the slug has no line.
3. A write needs a slug that matches `^[a-z0-9]+(-[a-z0-9]+)*$` and a status from `STATUSES`. Otherwise exit 2.
4. For a new slug, exactly one of `--match` and `--nudge` is required. Exit 2 otherwise.
5. For an existing slug, each field the call does not give is copied from the current entry. `--match` on a nudge entry, or `--nudge` on a sig entry, changes its kind.
6. `fixed` and `verified` need a `fixed_on` (given or copied) in `YYYY-MM-DD` form that `datetime.date.fromisoformat` accepts. `ignored` needs a non-empty note. A `match` must pass `re.compile`. Each failure exits 2.
7. Build the line, then call `WL._fit(line)`. If `_fit` returns `None`, or the decoded result differs from the input in `slug`, `kind`, `match`, `status`, `pr` or `fixed_on`, exit 2 with `mark: refused, the line changed in the secret scrub or the 512-byte cap: <keys>`. If only `note` changed, keep the scrubbed note and print `mark: note scrubbed or shortened`.
8. Write with `WL.write_line(ledger_path(), line)`. If it returns False, print `warden-lesson: capture is disabled; run warden-lesson status` to stderr and exit 1.
9. After a write, print the `--list` line for the slug. Task 2 adds the match output.

In `warden-lesson`: define the `mark` subparser in `main()` beside the others, with `set_defaults(func=lambda a: _ledger().mark_cmd(a))`. The module loads only inside that handler. Do not import or load the module at the top of the file, in `_hook`, or in `_nudge`. Update the docstring to `Modes: hook, nudge, add, list, report, status, mark, weekly, schedule.`

Tests in `tests/warden_ledger.sh`. Source `tests/lib/harness.sh`, call `harness_setup`, and copy the `py`, `fresh_root` and `WL` helpers from `tests/warden_lessons.sh` (lines 10 to 25 and 391). End the file with `harness_teardown` and `exit $((FAILURES > 0))`, the same as `tests/warden_lessons.sh`.
- T1: run the hook mode in-process with a fail payload, through `py`, by calling `wl._hook(...)` the same way `tests/warden_lessons.sh` does, then call `wl.main(["hook"])` with the payload on stdin, and assert `"warden_ledger" not in sys.modules` after each call. A control case calls `wl._ledger()` and asserts that the name is then present, so the check can fail.
- T2: make a temporary folder with a symlink `bin -> $REPO_DIR/bin`. The wrapper resolves the symlink with `cd -P`, so it runs the real script under `python3 -I`. Run `<tmp>/bin/warden-lesson mark a-b open --match x`, then `<tmp>/bin/warden-lesson mark --list`. Assert exit 0 and that the list shows `a-b`.
- T3: no new test. The existing timing tests in `tests/warden_lessons.sh` (H10 and the production median) stay green.
- T4: mark `s` fixed with `--fixed-on 2026-11-10 --pr 11 --match a`, then mark `s` open. Assert `--list` shows open. Mark `s` fixed again with no other flags. Assert `--list` shows fixed with `#11 2026-11-10`, and `--history` prints 3 lines.
- T5: mark `s` open `--match a --note n1`, then mark `s` verified `--fixed-on 2026-11-10`. Assert the current entry keeps `match` `a` and note `n1`.
- T6: each of these exits 2 and leaves the ledger byte for byte the same: status `done`, slug `Bad_Slug`, new slug without `--match` or `--nudge`, `fixed` without `--fixed-on`, `--fixed-on 2026-13-01`, `ignored` without `--note`, `--match '('`, `--match` holding a 41-character run of letters (scrub), a note of 600 characters plus a 300-character match (cap).
- T8: write 2 ledger lines, set the ledger mtime 40 days back with `touch -t`, remove `<inbox>/.retention`, and call `wl.retention()`. Assert the ledger checksum is unchanged.
- T9 (part): take a `shasum` of every file in the inbox, run `WL report`, `WL status` and `mark --list`, and assert the checksums are unchanged.
- Mode: assert the ledger has mode 600.

Test command: `bash tests/warden_ledger.sh && bash tests/warden_lessons.sh`

**Steps:**
- [ ] Write T1, T2, T4, T5, T6, T8, T9 and the mode check in `tests/warden_ledger.sh`.
- [ ] Run `bash tests/warden_ledger.sh` and see the tests fail because `mark` is an unknown mode.
- [ ] Write `warden_ledger.py` with `STATUSES`, `ledger_path`, `read_ledger` and `mark_cmd`.
- [ ] Add `_ledger()` and the `mark` registration to `warden-lesson`, and update the docstring.
- [ ] Run `bash tests/warden_ledger.sh` and see every test pass.
- [ ] Run `bash tests/warden_lessons.sh` and see it stay green, including both timing tests.
- [ ] Commit: `feat: add the lessons ledger and warden-lesson mark`.

---

### Task 2: Matching, the after-fix rule, the report decoration and the `mark` match output

**Satisfies:** REQ-1, REQ-2, REQ-3, REQ-4

**Files:**
- Modify: `plugins/warden/scripts/warden_ledger.py`
- Modify: `plugins/warden/scripts/warden-lesson` (`HIDE_REASONS`, `report_rows`, `nudge_rows`, `_report`)
- Modify: `tests/warden_ledger.sh`

**Depends on:** Task 1

**Model:** `sonnet` (standard tier). The task crosses two production files.

**Interfaces:**
- Consumes: `_ledger()`, `read_ledger()`, `mark_cmd(args)`.
- Produces, in `warden-lesson`:
  - `HIDE_REASONS = ("fixed test failure", "one-off exception", "no signature", "ignored")`.
  - Each row from `report_rows()` carries `"session_names"`: a sorted list of session file names without `.jsonl`.
  - Each row from `nudge_rows()` carries `"session"`: its session file name without `.jsonl`.
  - `format_report(rows, lessons, nudges, hidden) -> list[str]`: the exact lines `_report` prints today. A row with a `"ledger_tag"` key gets ` ledger(<tag>)` as the last field, after `flaky` and before `hidden(...)`.
- Produces, in `warden_ledger.py`:
  - `session_days() -> dict`: session name to a `datetime.date`, the local date of the first parsed line's `ts`. A session with no parsed line or no `ts` is absent.
  - `ledger_view(include_hidden) -> dict` with keys `recurring` (list of dicts with `entry`, `after_sessions`, `rows`, `nudges`), `rows`, `lessons`, `nudges`, `hidden`, `footer` (list of strings), `unacknowledged` (int).
  - `render_report(view) -> str`: the full report text, the same text that `report` prints.

**Brief:** Make the report show ledger decisions, and make `mark` show what a regex matches.

Matching rules:
1. A sig entry matches a row when `re.search(entry["match"], row["norm"])` is true.
2. A nudge entry matches each nudge row whose `followed` is False.
3. When two entries match one row, the entry with the latest `ts` wins.
4. Skip entries in `read_ledger()["skipped"]`.

After-fix rule: a row's after-fix sessions are its `session_names` whose day in `session_days()` is later than the entry's `fixed_on`. A nudge row is after the fix when its `session` day is later than `fixed_on`. An entry is recurring when its status is `fixed` or `verified` and it has at least one after-fix row or nudge.

`ledger_view(include_hidden)`:
1. Call `WL.report_rows(include_hidden=True)` and `WL.nudge_rows()`.
2. Recurring entries take their matching rows out of the main list, even when the row has a `hidden` reason. When such a row had a hidden reason, decrement that reason's count in `hidden`.
3. A row that matches an ignored entry, and has no other hidden reason, gets `hidden = "ignored"`, and `hidden["ignored"]` goes up by 1.
4. A row that matches an `open`, `fixed` or `verified` entry gets `ledger_tag = "<slug>:<status>"`.
5. When `include_hidden` is False, drop rows with a `hidden` reason.
6. `unacknowledged` counts the flagged rows that no entry matches.
7. `footer` gets `ledger: N entries skipped (bad regex: a, b)` when entries were skipped, and `ledger: unreadable` when the file cannot be read.
8. Order the recurring blocks by the newest after-fix session day, newest first.

`render_report(view)` prints, in this order:
1. When `recurring` is not empty: `Fixed but recurring:`. Then for each block a header line `!!  <slug>  <status> #<pr> <fixed_on>  <N> session(s) after fix`, with `#<pr>` left out when there is no PR. Under the header come the rows in the `format_report` row format and the nudges in the nudge format, each indented by 6 spaces. Then one blank line.
2. The lines from `WL.format_report(...)`.
3. The `footer` lines.

`_report` in `warden-lesson`: when `ledger.jsonl` does not exist, or has a size of 0, print `format_report(...)` exactly as today and do not load the module. Otherwise print `_ledger().render_report(_ledger().ledger_view(args.all))`.

`mark` match output: after a write, print `  matches: <S> signatures, <T> sessions, <A> after fix`, using `ledger_view(include_hidden=True)` matching for this one entry. Then print at most 10 matching rows, indented by 2 spaces in the row format, then `  +N more` when there are more. For a nudge entry, count nudges in place of signatures. When the new regex matches a row that another entry also matches, print `mark: warning, also matched by <slug>` once per other slug.

Tests in `tests/warden_ledger.sh`. Build session files with lines in the inbox format: `fail` lines with `ts`, `cmd`, `exit`, `sig`, `repo`, and `nudge` and `setup-call` lines in the shape that `tests/warden_lessons.sh` lines 755 and 756 use. Set `TZ=Europe/Oslo`.
- T7: three sessions hold `(eval):1: ==== not found`, and one holds `KeyError: 'x'` (hidden as a one-off exception). `mark w open --match '^\(eval\):N: \S+ not found$'` prints `matches: 1 signatures, 3 sessions, 0 after fix`. `mark k open --match KeyError` prints 1 signature, so hidden rows count. Twelve distinct matching signatures print 10 rows and `+2 more`. A second entry with `--match 'not found'` prints `also matched by w`.
- T10: with no ledger file, and then with an empty ledger file, `WL report` and `WL report --all` print the same bytes as the reference script. Save the reference with `git -C $REPO_DIR show 49faf2b:plugins/warden/scripts/warden-lesson > $HARNESS_TMP/ref`, which is the script before Task 1, and run it with `python3 -I` against the same inbox.
- T11: entry `fixed` with `fixed_on` 2026-11-10. One session has its first line on 2026-11-11 and one matching fail line, and that row is s1 `KeyError` (hidden as a one-off). The report starts with `Fixed but recurring:`. The header holds the slug, `fixed #11 2026-11-10` and `1 session after fix`. The row sits under it, indented by 6 spaces. The row does not appear in the main list. The hidden count for one-off exceptions is 1 lower.
- T12: entry `fixed` with `fixed_on` 2026-11-10. The session's first line is an `edit` at `2026-11-10T20:00:00Z` (local day 2026-11-10). Its matching fail line is at `2026-11-11T09:00:00Z`. The report has no `Fixed but recurring:` section.
- T13: entry `setup-check-miss` with kind `nudge`, `fixed`, and `fixed_on` 2026-11-25. A session starting on 2026-11-26 holds a nudge for repo `r` with no later setup-call. The report shows the block with `no setup-call`. A second case adds a later setup-call for `r`, and the block disappears.
- T14: an ignored entry hides its row. The footer counts `1 ignored` as the last reason. `--all` shows `hidden(ignored)`. An open entry's row ends with `ledger(<slug>:open)`. A fixed entry with no after-fix session tags its row `ledger(<slug>:fixed)`.
- T15: two entries match one row. The entry written later supplies the tag. Write them in the other order, and the other entry supplies the tag.
- T16: append a raw line with `"match":"("` for slug `bad`. The report exits 0 and ends with `ledger: 1 entries skipped (bad regex: bad)`. Make the ledger unreadable with `chmod 000`. The report exits 0 and ends with `ledger: unreadable`. Restore the mode afterwards.

Test command: `bash tests/warden_ledger.sh && bash tests/warden_lessons.sh`

**Steps:**
- [ ] Write T7, T10, T11, T12, T13, T14, T15 and T16.
- [ ] Run `bash tests/warden_ledger.sh` and see them fail.
- [ ] In `warden-lesson`, move the printing in `_report` into `format_report`, and add the `ledger_tag` field.
- [ ] Run `bash tests/warden_lessons.sh` and see the existing report tests stay green.
- [ ] Add `session_names`, the nudge `session` key and the `ignored` hide reason.
- [ ] Write `session_days`, `ledger_view` and `render_report`, and route `_report` to them when the ledger has content.
- [ ] Add the match output and the overlap warning to `mark_cmd`.
- [ ] Run `bash tests/warden_ledger.sh && bash tests/warden_lessons.sh` and see every test pass.
- [ ] Commit: `feat: show ledger decisions and fixed-but-recurring entries in the report`.

---

### Task 3: The weekly run and the `weekly:` status line

**Satisfies:** REQ-5, REQ-6, REQ-7

**Files:**
- Modify: `plugins/warden/scripts/warden_ledger.py`
- Modify: `plugins/warden/scripts/warden-lesson` (`_status`, `main()`)
- Create: `tests/stubs/osascript`
- Modify: `tests/warden_ledger.sh`

**Depends on:** Task 2

**Model:** `sonnet` (standard tier). The task crosses two production files and a stub.

**Interfaces:**
- Consumes: `ledger_view(include_hidden)`, `render_report(view)`.
- Produces, in `warden_ledger.py`:
  - `now() -> datetime.datetime`: local time, or `WARDEN_NOW` parsed with `datetime.datetime.fromisoformat` when set.
  - `weekly_dir() -> str`: `<inbox>/weekly`.
  - `notify(message) -> int`: runs `osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' 'Warden lessons' <message>` and returns its exit code. It returns 127 when `osascript` is not on PATH.
  - `weekly_cmd(args) -> int`.
  - `status_lines() -> list[str]`: Task 3 returns the `weekly:` line only. Task 4 adds the `schedule:` line.
- Produces, in `tests/stubs/osascript`: a bash script that appends `osascript <args>` to `$WARDEN_STUB_LOG` and exits with `${WARDEN_STUB_OSASCRIPT_EXIT:-0}`.

**Brief:** Add `warden-lesson weekly` and the `weekly:` status line.

`weekly_cmd`:
1. Build `view = ledger_view(False)` and `text = render_report(view)`. When the ledger is empty or missing, use the same text that `report` prints.
2. Create `weekly_dir()` with mode 700. Write `text` to `report-<now().date()>.txt.tmp`, then `os.replace` it to `report-<date>.txt`.
3. R = `len(view["recurring"])`. U = `view["unacknowledged"]`.
4. When R + U > 0, call `notify("<R> fixed entr(y|ies) recurring, <U> flagged signature(s) without an entry.\n<report path with the home folder shown as ~>")`.
5. Sort the `report-*.txt` names. Delete all but the 12 newest. Touch no other file.
6. Write `last-run` as one JSON object through a temporary file and `os.replace`: `ts` (`now()` ISO, seconds), `report`, `recurring`, `unacknowledged`, `notified` (bool), and `error` when a step failed (`report write failed: <reason>` or `notify failed: <exit code>`).
7. Exit 1 when the report write or the notification failed. Exit 0 otherwise.

`status_lines()` builds the `weekly:` line:
- No `last-run`: `weekly: never run`.
- Otherwise: `weekly: last run <YYYY-MM-DD HH:MM>, <R> recurring entr(y|ies), <U> unacknowledged, notified|not notified`, then `, error: <error>` when `error` is set, then ` STALE` when `now()` minus `ts` is more than 8 days.
- A `last-run` that does not parse gives `weekly: last-run unreadable`.

`_status` in `warden-lesson` prints its four existing lines unchanged, then each line of `_ledger().status_lines()`. Define the `weekly` subparser in `main()` with `set_defaults(func=lambda a: _ledger().weekly_cmd(a))`.

Tests (`WARDEN_NOW` set, stub log cleared before each case):
- T17: an inbox with no flagged row and no ledger. `weekly` exits 0, writes `report-2026-11-30.txt` and `last-run` with `notified` false, and the stub log has no `osascript` line.
- T18: one fixed entry with two after-fix rows. The stub log has one `osascript` line, and it holds `1 fixed entry recurring, 0 flagged signatures without an entry.` and `report-2026-11-30.txt`. The line holds no signature text.
- T18b: one fixed entry whose only matching session has a session day before its `fixed_on`. No `osascript` line.
- T19: one flagged row with no entry gives a notification with `1 flagged signature without an entry`. After `mark <slug> open --match <its regex>`, a second `weekly` sends no notification.
- T20: run `weekly` 14 times with `WARDEN_NOW` on 14 different Mondays. Exactly 12 `report-*.txt` files remain, the oldest two are gone, and `last-run`, `schedule.json` and `launchd.err` (created empty before the runs) still exist.
- T21: `WARDEN_STUB_OSASCRIPT_EXIT=1` with a flagged row. `weekly` exits 1, and `last-run` holds `notify failed: 1`.
- T26 (weekly part): `status` without `last-run` prints `weekly: never run` as line 5. After a run, it prints the run time and counts. With `WARDEN_NOW` 9 days later, the line ends with `STALE`. After T21, the line shows `error: notify failed: 1`. The first four lines equal the output of the reference script from T10.
- T9 (rest): take checksums of the ledger and of every inbox file outside `weekly/`, run `weekly` and `status`, and compare.

Test command: `bash tests/warden_ledger.sh && bash tests/warden_lessons.sh`

**Steps:**
- [ ] Write the `osascript` stub and make it executable.
- [ ] Write T17, T18, T18b, T19, T20, T21, the weekly part of T26, and the rest of T9.
- [ ] Run `bash tests/warden_ledger.sh` and see them fail.
- [ ] Write `now`, `weekly_dir`, `notify`, `weekly_cmd` and `status_lines`.
- [ ] Register `weekly` and extend `_status`.
- [ ] Run `bash tests/warden_ledger.sh && bash tests/warden_lessons.sh` and see every test pass.
- [ ] Commit: `feat: add warden-lesson weekly and the weekly status line`.

---

### Task 4: `schedule install`, `uninstall`, `confirm` and the `schedule:` status line

**Satisfies:** REQ-6, REQ-9

**Files:**
- Modify: `plugins/warden/scripts/warden_ledger.py`
- Modify: `plugins/warden/scripts/warden-lesson` (`main()`)
- Modify: `bin/warden-lesson` (comment line 2)
- Create: `tests/stubs/launchctl`
- Modify: `tests/warden_ledger.sh`

**Depends on:** Task 3

**Model:** `sonnet` (standard tier). The task crosses three production files and a stub.

**Interfaces:**
- Consumes: `notify(message) -> int`, `weekly_dir()`, `status_lines()`.
- Produces, in `warden_ledger.py`: `schedule_cmd(args) -> int`, `LABEL = "com.warden.lesson-weekly"`, `plist_path() -> str` (`<WARDEN_LAUNCH_AGENTS or ~/Library/LaunchAgents>/com.warden.lesson-weekly.plist`).
- Produces, in `tests/stubs/launchctl`: a bash script that appends `launchctl <args>` to `$WARDEN_STUB_LOG` and exits with `${WARDEN_STUB_LAUNCHCTL_EXIT:-0}`.

**Brief:** Install and remove the launchd agent safely, and report its state in `status`.

`schedule install`:
1. Let `bin = os.path.expanduser("~/.claude/bin")`. If it does not exist, print `schedule: refused, ~/.claude/bin does not exist` and exit 2.
2. Let `checkout = os.path.dirname(os.path.realpath(bin))`. If `<checkout>/.git` is a file, print `schedule: refused, <checkout> is a git worktree; install from the main checkout` and exit 2.
3. Let `script = <checkout>/plugins/warden/scripts/warden-lesson`. If it does not exist, refuse with exit 2.
4. Let `python = shutil.which("python3")`. Do not resolve it. If it is None, print `schedule: refused, no python3 on PATH` and exit 2.
5. Build the plist from a template string in the module, with `plistlib.dumps`: `Label`, `ProgramArguments` = `[python, "-I", script, "weekly"]`, `StartCalendarInterval` = `{"Weekday": 1, "Hour": 9, "Minute": 15}`, `StandardErrorPath` = `<weekly_dir()>/launchd.err`, `RunAtLoad` false. Create the plist folder if needed. Write the file with mode 644 through a temporary file and `os.replace`.
6. Run `launchctl bootout gui/<uid>/com.warden.lesson-weekly`, and ignore its exit code. Then run `launchctl bootstrap gui/<uid> <plist>`. If `bootstrap` fails, print its output and exit 1.
7. Call `notify("Test notification from schedule install.")`.
8. Print the plist path, the script, the interpreter and `next run: Monday 09:15`.
9. If `sys.stdin.isatty()`, ask `Did you see the test notification? [y/N] `. On `y` or `yes`, write `schedule.json` as `{"confirmed": "<now ISO>"}`. On any other answer, print: `Notifications from osascript appear under Script Editor. Allow them in System Settings > Notifications > Script Editor. If Script Editor is not listed, open Script Editor, run: display notification "test", and allow the prompt. Then run: warden-lesson schedule confirm`. Exit 0 in both cases.
10. Without a terminal, print `Run warden-lesson schedule confirm after you see the test notification.` and exit 0.

`schedule confirm` writes `schedule.json` as in step 9 and exits 0.

`schedule uninstall`: when the plist does not exist, print `schedule: not installed` and exit 0. Otherwise run `launchctl bootout gui/<uid>/com.warden.lesson-weekly`, ignore its exit code, delete the plist, print `schedule: uninstalled`, and exit 0. Keep the weekly folder.

`status_lines()` adds the `schedule:` line after the `weekly:` line. Read the plist with `plistlib`, and show the first state that applies:
1. No plist: `schedule: not installed`.
2. `ProgramArguments[2]` does not exist: `schedule: broken (script missing: <path>)`.
3. `ProgramArguments[0]` does not exist: `schedule: broken (interpreter missing: <path>)`.
4. No `confirmed` in `schedule.json`: `schedule: installed, Monday 09:15, notification unconfirmed`.
5. Otherwise: `schedule: installed, Monday 09:15`.

Define the `schedule` subparser in `main()` with one positional argument limited to `install`, `uninstall` and `confirm`, and `set_defaults(func=lambda a: _ledger().schedule_cmd(a))`. Change line 2 of `bin/warden-lesson` to `# warden-lesson - the lesson inbox: add, list, report, status, mark, weekly, schedule. Runs the plugin script.`

Tests. Each test builds a fake main checkout in `$HARNESS_TMP/co` with a `.git` folder, `plugins/warden/scripts/warden-lesson` (a copy), and `bin/`. Then it links `$HOME/.claude/bin -> $HARNESS_TMP/co/bin` and sets `WARDEN_LAUNCH_AGENTS=$HARNESS_TMP/agents`.
- T22: `schedule install < /dev/null` exits 0. The plist has `ProgramArguments` `[<which python3>, "-I", "$HARNESS_TMP/co/plugins/warden/scripts/warden-lesson", "weekly"]`, where the first value is the unresolved path. It has Weekday 1, Hour 9, Minute 15. The stub log shows `launchctl bootout` before `launchctl bootstrap`, and one `osascript` line with `Test notification`. A second install leaves one plist and logs `bootout` again.
- T23: with `.git` as a file in the checkout, install exits 2, the message holds `is a git worktree`, and no plist exists. Without `$HOME/.claude/bin`, install exits 2.
- T24: install with stdin from `/dev/null` prints `schedule confirm`, and `status` shows `notification unconfirmed`. `schedule confirm` then makes `status` show `schedule: installed, Monday 09:15`. With a terminal: `printf 'y\n' | script -q /dev/null <cmd> schedule install` makes `schedule.json` hold `confirmed`.
- T25: uninstall removes the plist, logs `launchctl bootout`, and keeps `weekly/`. A second uninstall prints `schedule: not installed` and exits 0.
- T26 (schedule part): `not installed`. After install, delete the script copy: `broken (script missing: ...)`. Restore it, and rewrite the plist with a missing interpreter path: `broken (interpreter missing: ...)`.
- T27: no new test. Run `bash tests/no_machine_content.sh` and see it pass.

Test command: `bash tests/warden_ledger.sh && bash tests/no_machine_content.sh && bash tests/warden_lessons.sh`

**Steps:**
- [ ] Write the `launchctl` stub and make it executable.
- [ ] Write T22, T23, T24, T25 and the schedule part of T26.
- [ ] Run `bash tests/warden_ledger.sh` and see them fail.
- [ ] Write `LABEL`, `plist_path`, `schedule_cmd` and the `schedule:` status line.
- [ ] Register `schedule`, and change the comment in `bin/warden-lesson`.
- [ ] Run the test command and see every test pass.
- [ ] Commit: `feat: add warden-lesson schedule for the Monday report`.

---

### Task 5: The seed script

**Satisfies:** REQ-10

**Files:**
- Create: `docs/superpowers/changes/2026-11-lessons-ledger-weekly-report/seed.sh`
- Create: `tests/warden_ledger_seed.sh`

**Depends on:** Task 2

**Model:** `sonnet` (standard tier). Its behaviour depends on the `mark` output from two earlier tasks.

**Interfaces:**
- Consumes: `warden-lesson mark` with `--match`, `--nudge`, `--pr`, `--fixed-on`, `--note`, `--list`.

**Brief:** Give Nicolai one short command that writes the four seed entries.

`seed.sh` runs the lesson command from `${WARDEN_LESSON:-warden-lesson}`. It reads `mark --list` first and skips every slug that already has an entry, so a second run writes nothing. It writes these entries, in this order:

| Slug | Flags |
|---|---|
| `zsh-equals-word` | `verified --match '^\(eval\):N: \S+ not found$' --pr 11 --fixed-on 2026-11-10 --note 'zsh =word expands to a command path. The hook denies an unquoted =word since #11.'` |
| `zsh-include-glob` | `verified --match '^\(eval\):N: no matches found: \S*--include=' --pr 11 --fixed-on 2026-11-10 --note '0 occurrences in the 9 sessions from 2026-11-10 to 2026-11-17, the week after #11.'` |
| `setup-check-miss` | `fixed --nudge --pr 13 --fixed-on 2026-11-25 --note 'Live check pending. Matches a nudge with no setup-call, so it cannot see a miss where no nudge fired.'` |
| `hedges-output-line` | `ignored --match '^Hedges<path> \(may, might, could\)' --note 'A script output line, not a failure.'` |

The script prints each `mark` output, then `mark --list`. It stops at the first `mark` that exits non-zero, and exits with that code.

Tests in `tests/warden_ledger_seed.sh` (source the harness, use a temporary `WARDEN_LESSON_ROOT`, set `WARDEN_LESSON="python3 -I $REPO_DIR/plugins/warden/scripts/warden-lesson"`):
- One session file holds a fail line with sig `(eval):1: ==== not found`, and one holds sig `Hedges<path> (may, might, could) are never flagged: confidence is content.` in three sessions.
- `seed.sh` exits 0. The output shows `matches: 1 signatures` for `zsh-equals-word` and `matches: 0 signatures` for `zsh-include-glob`.
- `mark --list` shows the four slugs with `verified`, `verified`, `fixed` and `ignored`.
- `report` no longer lists the Hedges row and counts `1 ignored`.
- A second `seed.sh` run leaves the ledger byte for byte the same.

Test command: `bash tests/warden_ledger_seed.sh`

**Steps:**
- [ ] Write `tests/warden_ledger_seed.sh`.
- [ ] Run it and see it fail because `seed.sh` does not exist.
- [ ] Write `seed.sh` and make it executable.
- [ ] Run `bash tests/warden_ledger_seed.sh` and see every check pass.
- [ ] Commit: `feat: add the seed script for the lessons ledger`.

---

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1 | Every later task needs the module and the loader. |
| 2 | 2 | It needs Task 1. |
| 3 | 3, 5 | Both need Task 2. Task 3 owns the module, the lesson script, the ledger tests and the `osascript` stub. Task 5 owns `seed.sh` and its own test file. |
| 4 | 4 | It needs Task 3 (`notify`, `status_lines`) and owns the same module. |

After the last wave: the final review, the fix wave and the scoped re-review, then `reconciling-specs`.

## After the merge (Nicolai)

1. `bash docs/superpowers/changes/2026-11-lessons-ledger-weekly-report/seed.sh` in the main checkout.
2. `warden-lesson schedule install` in a terminal, then answer the notification question.
3. Read the first Monday report on 2026-11-30.

## Requirement coverage

| Requirement | Tasks |
|---|---|
| REQ-1 | 1, 2 |
| REQ-2 | 2 |
| REQ-3 | 2 |
| REQ-4 | 2 |
| REQ-5 | 3 |
| REQ-6 | 3, 4 |
| REQ-7 | 1, 3 |
| REQ-8 | 1 |
| REQ-9 | 4 |
| REQ-10 | 5 |

## Spec points this plan reads differently

- **P1. REQ-7.1 names a lock that does not exist.** `write_line` holds no lock. It writes each line with one `O_APPEND` write of at most 512 bytes. The plan reuses `write_line` unchanged. Proposed ruling: REQ-7.1 reads "with the single append write of the inbox writer".
- **P2. The secret scrub and the 512-byte cap can change a ledger line.** The plan makes `mark` refuse when the scrub or the cap changes `slug`, `kind`, `match`, `status`, `pr` or `fixed_on`, and warn when only `note` changes. This adds refusal cases under REQ-1.7. The spec does not name them.
- **P3. The spec's open question has an answer.** `osascript` notifications appear under Script Editor in System Settings > Notifications. The `N` answer in Task 4 names it. This comes from forum reports and a Claude Code issue, not from Apple documentation.

## Risks, worst first

1. **The scrub silently changes a stored regex.** A changed `match` would mismatch every week without an error. Task 1 refuses such a write (P2), and T6 tests the scrub and the cap.
2. **The report output changes for an empty ledger.** Other tests and Nicolai's habits read that output. Task 2 skips the module when the ledger is missing or empty, and T10 compares bytes against the script from commit 49faf2b.
3. **The hook loads the new module.** That costs time on every tool call. T1 checks `sys.modules` and the import trace. The existing timing tests stay in place.
4. **The agent points at a path that later disappears.** The worktree refusal, the unresolved `python3` and the two `broken` status lines cover it. `STALE` shows a missed week.
5. **Notifications are blocked without an error.** `osascript` exits 0. The test notification and the confirmation catch a block at install time. A block that appears later stays invisible until a flagged week passes with no notification.
6. **Session days depend on the time zone.** Tests set `TZ=Europe/Oslo` and use timestamps close to midnight UTC (T12).

The task with the most risk is Task 2. It changes the report path that all existing report tests read, and it holds the matching and the after-fix rule.

Ruled out:
- A file lock for the ledger. The inbox writer has none, and one `mark` call at a time is the normal use.
- A second module for `schedule`. The spec and approach A1 name one module. Tasks 3 and 4 run one after the other, so they never share a wave.
- A JSON output mode for `report`. `weekly` calls `ledger_view` directly.
- User documentation in `README.md`. The README describes no `warden-lesson` mode today. The docstring and the `bin/warden-lesson` comment list the modes.
