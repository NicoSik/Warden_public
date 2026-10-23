# Lesson Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A silent hook in the `warden` plugin writes short, scrubbed failure lines to a lesson inbox outside every repository, and `warden-lesson` adds, lists and checks the inbox.

**Architecture:** One stdlib Python script, `plugins/warden/scripts/warden-lesson`, has four modes: `hook`, `add`, `list` and `status`. The plugin's `hooks.json` runs `warden-lesson hook` on `PostToolUseFailure` and `PostToolUse`, both async. Session logs are append-only JSONL. `list` derives the records.

**Tech Stack:** Python 3 stdlib (`json`, `re`, `hashlib`, `os`, `subprocess` for two `git` calls), bash tests in the `tests/lib/harness.sh` style.

**Spec:** `docs/superpowers/changes/2026-10-lesson-capture/spec.md`

## Global Constraints

- The inbox is `${WARDEN_LESSON_ROOT:-$HOME/.claude/lessons}`, with `sessions/<session_id>.jsonl` and `manual.jsonl`. Folders have mode 700, files mode 600.
- Every line is one JSON object of at most 512 bytes, written with one `os.write` on a file opened with `O_WRONLY|O_APPEND|O_CREAT`. Scrub and caps apply before the write.
- The scrub replaces each match with `<secret>`. Caps: `cmd` 40 characters, `sig` 120, lesson `text` 200.
- `fail` line keys, exactly: `t`, `ts`, `src`, `cmd`, `exit`, `sig`, `session_id`, `transcript_path`, `tool_use_id`, `repo`, `branch`, `commit`, and `h` for test-like commands only. `pass` keys: `t`, `ts`, `tool_use_id`, `h`. `edit` keys: `t`, `ts`. `lesson` keys: `t`, `ts`, `src`, `text`, `repo`, `branch`, `commit`, and `session_id` when `CLAUDE_CODE_SESSION_ID` is set.
- `h` is the first 16 hex characters of `sha256(command + "\0" + cwd)`.
- `ts` is UTC ISO 8601 with a trailing `Z`.
- The hook exits 0 and prints nothing in every case. `WARDEN_LESSON_OFF=1` makes it exit before it reads stdin.
- The script never writes when the inbox resolves inside a git work tree.
- `CLAUDE_CODE_SESSION_ID` names the session inside a Bash call (probe of 2026-10-23).
- Payload shapes, from the probe of 2026-10-23:
  - The `PostToolUseFailure` payload has keys `cwd`, `duration_ms`, `effort`, `error`, `hook_event_name`, `is_interrupt`, `permission_mode`, `prompt_id`, `session_id`, `tool_input` (`command`), `tool_name`, `tool_use_id` and `transcript_path`.
  - The `error` field starts with `Exit code N`, followed by the interleaved output.
  - The `PostToolUse` payload has `tool_response` with `stdout`, `stderr`, `interrupted`, `isImage` and `noOutputExpected`.
- Run Python as `python3 -I`. Write no `__pycache__`.
- No committed file holds a machine path.

---

### Task 1: The store, the scrub and retention

**Satisfies:** REQ-6, REQ-7

**Files:**
- Create: `plugins/warden/scripts/warden-lesson` (executable, `#!/usr/bin/env python3`)
- Create: `tests/warden_lessons.sh`

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Produces, inside the script: `inbox()` returns the resolved inbox path. `blocked_reasons()` returns a list drawn from `WARDEN_LESSON_OFF is 1`, `inside a git work tree` and `not writable`. `scrub(text) -> str`. `write_line(path, obj) -> bool` scrubs and caps every string value, cuts the encoded line to 512 bytes, writes it, and returns False on any error without raising. `retention()` deletes old session logs at most once a day, using the marker `<inbox>/.retention`.
- Produces a test helper style: each test sets `WARDEN_LESSON_ROOT` to a fresh temp folder.

**Brief:** Build the script skeleton with an `argparse` dispatcher for `hook`, `add`, `list` and `status`. The three non-hook modes stay stubs that exit 2 until later tasks. Implement the store helpers and the scrub.

The scrub covers every shape that `hooks/guard-secrets.sh` detects. Read that file and port each regex. It also covers `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9_-]{20,}`, `xox[abpr]-[A-Za-z0-9-]{10,}`, `Bearer\s+\S+`, `Authorization:\s*\S+(\s+\S+)?`, and `(password|token|secret|api_key)=\S+` (case-insensitive).

Tests in `tests/warden_lessons.sh`:
1. `write_line` creates the inbox (mode 700) and the file (mode 600).
2. A string value of 5,000 characters gives a line of at most 512 bytes that is valid JSON.
3. Each secret shape is planted in a value, and a grep of the written file for each planted value finds nothing.
4. A coverage check reads the shapes from `hooks/guard-secrets.sh`, builds one sample per shape, and asserts that `scrub` replaces each sample.
5. With the inbox inside a temporary `git init` folder, `write_line` returns False and writes nothing.
6. A read-only inbox makes `write_line` return False with no output.
7. Retention: session logs back-dated by 31 and 29 days with `touch -t`. Only the 31-day log is deleted. `manual.jsonl`, back-dated by 40 days, survives. A second call on the same day deletes nothing new.

To call internal functions, the tests run `python3 -I -c` and load the script with `importlib.machinery.SourceFileLoader`. Use `sys.dont_write_bytecode = True`.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Write tests 1–7. Run them and see them fail.
- [ ] Write the skeleton, the store helpers, the scrub and retention.
- [ ] Run `bash tests/warden_lessons.sh` and `bash tests/run.sh`, and see them pass.
- [ ] Commit: `feat: add the lesson store and secret scrub`.

### Task 2: Capture in the hook mode

**Satisfies:** REQ-1, REQ-2, REQ-3, REQ-9

**Files:**
- Modify: `plugins/warden/scripts/warden-lesson` (the `hook` mode)
- Modify: `tests/warden_lessons.sh`

**Depends on:** 1

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Consumes: `inbox()`, `blocked_reasons()`, `scrub()`, `write_line()` and `retention()` from Task 1.
- Produces: `last_simple(command) -> str`, `is_test_like(command) -> bool`, `signature(error) -> str`, and `cmd_name(command) -> str`.

**Brief:** `warden-lesson hook` reads one payload from stdin.
- **Off switch.** If `WARDEN_LESSON_OFF` is `1`, it exits 0 before reading stdin.
- **`PostToolUseFailure` with `tool_name` = `Bash`.** It parses `Exit code N` and applies the skips of REQ-1.2 and REQ-1.3. Otherwise it writes a `fail` line with the exact keys from Global Constraints.
- **`sig`.** The first output line after `Exit code N` matching `error|fail|fatal|not found|denied|no such|cannot` (case-insensitive). Else the last non-empty line. Paths become `<path>` (`(~|\.{1,2})?/[^\s:'"]+` and Windows-style `[A-Za-z]:\\\S+`), the result is scrubbed, then cut to 120 characters.
- **`repo`, `branch`, `commit`.** From `git -C <cwd> rev-parse --show-toplevel`, `--abbrev-ref HEAD` and `--short HEAD`, with a 2-second timeout each, and empty on any error.
- **`PostToolUse`.** For a test-like Bash command, a `pass` line. For Edit, Write, MultiEdit or NotebookEdit, an `edit` line.
- **Retention.** It calls `retention()` once per run.
- **Errors.** Every exception is caught. The mode always exits 0 and prints nothing.

Tests:
1. `false` (`Exit code 1`, no output): one `fail` line, `cmd` = `false`, `sig` = empty string, the exact key set.
2. A pytest-style failure, with these output lines: `============ test session starts ============`, `collected 3 items`, `tests/test_x.py F..`, `E   AssertionError: assert 2 == 3`, `FAILED tests/test_x.py::test_add - AssertionError`. `sig` is the `E   AssertionError…` line with paths replaced, not the header line.
3. Output with no matching line: `sig` is the last non-empty line.
4. Skips: exit 0, 130, 143, `is_interrupt` true, `grep foo x` exit 1, `cd a && rg x` exit 1, `git diff --quiet` exit 1, `test -f x` exit 1. Each writes nothing. `grep foo x` with exit 2 writes a line.
5. `cmd`: `git push origin main` gives `git push`. `/usr/bin/python3 -c x` gives `python3`. A 60-character first word is cut to 40 characters.
6. Test-like list: each REQ-3.1 form gives `h`, and `ls` gives no `h`. A `PostToolUse` for `pytest -q` writes a `pass` line with exactly `t`, `ts`, `tool_use_id`, `h`. A `PostToolUse` for `ls` writes nothing. Edit, Write, MultiEdit and NotebookEdit each write an `edit` line with exactly `t`, `ts`.
7. The full command text never appears in any line. Use a command with a unique marker word in an argument after the second word.
8. A secret planted in the failure output is not in the inbox.
9. `WARDEN_LESSON_OFF=1` with no stdin (`</dev/null` and a payload that would write) writes nothing and exits 0. Invalid JSON on stdin exits 0 with no output. A read-only inbox exits 0 with no output.
10. Timing: 20 runs with a `fail` payload. The median wall time is under 50 ms.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Write tests 1–10. Run them and see them fail.
- [ ] Write the hook mode and its helpers.
- [ ] Run `bash tests/warden_lessons.sh` and `bash tests/run.sh`, and see them pass.
- [ ] Commit: `feat: capture clear Bash failures and test passes in the lesson hook`.

### Task 3: `add`, `list`, `status` and the bin wrapper

**Satisfies:** REQ-4, REQ-5, REQ-11

**Files:**
- Modify: `plugins/warden/scripts/warden-lesson` (the `add`, `list` and `status` modes)
- Create: `bin/warden-lesson` (bash, executable)
- Modify: `tests/warden_lessons.sh`

**Depends on:** 2

**Model:** `sonnet` (standard tier).

**Interfaces:**
- Consumes: Task 1's store helpers and Task 2's line formats.
- Produces: the CLI `warden-lesson add "<text>" [--by agent]`, `warden-lesson list [--json]` and `warden-lesson status`.

**Brief:**
- **`add`.** Writes a `lesson` line to `manual.jsonl`. `src` is `user`, or `agent` with `--by agent`. `text` is scrubbed and cut to 200 characters. `session_id` comes from `CLAUDE_CODE_SESSION_ID` when set. An empty or missing text exits 2 with `usage: warden-lesson add "<text>" [--by agent]`.
- **`list`.**
  - It reads every session log and the manual log and skips invalid lines.
  - Per session, it groups `fail` lines by (`cmd`, `exit`, `sig` with each digit run replaced by `N`), keeping the first line's `sig` and a `count`.
  - A group is `fixed` when a later `pass` line in the same log has its `h`. It then shows that `pass` line's `tool_use_id` and the number of `edit` lines between the group's last `fail` line and that `pass` line.
  - Rows are printed newest first: `date  src  repo  cmd  sig-or-text  xcount  fixed`.
  - `--json` prints one JSON object per record.
- **`status`.** Prints four lines, `inbox: <path>`, `capture: enabled` or `capture: disabled (<reasons joined by ", ">)`, `records: <n>` and `last write: <ts or never>`. It exits 0 in every case.
- **`bin/warden-lesson`.** Resolves its own folder with `cd -P` and runs `python3 -I "<repo>/plugins/warden/scripts/warden-lesson" "$@"`.

Tests:
1. A repeated failure (3 identical `fail` lines) gives one record, `count` 3.
2. Two failures that differ only in numbers (`Error: port 3000 in use` and `Error: port 3001 in use`) give one record, `count` 2. The record keeps `port 3000`.
3. A fixed test: a `fail` with `h`, then two `edit` lines, then a `pass` with the same `h`. The record shows `fixed` true, the pass `tool_use_id`, and edits 2.
4. A plain rerun (a `fail`, then a `pass`) shows edits 0.
5. A corrupt line in a session log is skipped, and the other records still list.
6. `add "fix the flaky port test"` gives `src` user. `add --by agent "x"` gives `src` agent. A planted secret in the text is absent from the inbox. A 300-character text is stored as 200 characters. No text exits 2 with the usage line. With `CLAUDE_CODE_SESSION_ID=abc`, the line holds `session_id` abc.
7. `list` orders the rows newest first and shows `src`. `list --json` gives valid JSON lines.
8. `status` on an empty inbox prints `records: 0` and `last write: never`. After two writes, it prints the count and the last `ts`. With `WARDEN_LESSON_OFF=1`, it prints `disabled (WARDEN_LESSON_OFF is 1)`. With a read-only inbox, it prints `disabled (not writable)`. With `WARDEN_LESSON_ROOT` inside a temporary `git init` folder, it prints `disabled (inside a git work tree)`.
9. `bin/warden-lesson status` works from another folder.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Write tests 1–9. Run them and see them fail.
- [ ] Write `add`, `list`, `status` and `bin/warden-lesson`.
- [ ] Run `bash tests/warden_lessons.sh` and `bash tests/run.sh`, and see them pass.
- [ ] Commit: `feat: add warden-lesson add, list and status`.

### Task 4: Register the hook in the warden plugin

**Satisfies:** REQ-8

**Files:**
- Modify: `plugins/warden/hooks/hooks.json`
- Modify: `tests/warden_hooks.sh`

**Depends on:** none

**Model:** `sonnet` (standard tier).

**Brief:**
- **New entries.** Add `PostToolUseFailure` with matcher `Bash`, and `PostToolUse` with matcher `Bash|Edit|Write|MultiEdit|NotebookEdit`. Each runs `"${CLAUDE_PLUGIN_ROOT}/scripts/warden-lesson" hook` with `"async": true`, and with `"shell": "bash"` as the existing entries have.
- **Existing entries.** Keep `SessionStart` and `SubagentStart` byte-identical.

Tests in `tests/warden_hooks.sh`:
- the two new entries, their matchers and `async: true`;
- the command path, and that `scripts/warden-lesson` exists or is created by another task (assert the path string only);
- that the `SessionStart` and `SubagentStart` entries equal their old JSON;
- that no entry sets `onFailure`, an existing check that must keep passing.

Test command: `bash tests/warden_hooks.sh`.

**Steps:**
- [ ] Write the assertions. Run them and see them fail.
- [ ] Edit `hooks.json`.
- [ ] Run `bash tests/warden_hooks.sh` and `bash tests/run.sh`, and see them pass.
- [ ] Commit: `feat: register the lesson hook in the warden plugin`.

### Task 5: Eval isolation check

**Satisfies:** REQ-10

**Files:** none committed. The result goes into the PR body.

**Depends on:** 3, 4

**Model:** session. One agent run on plan usage.

**Brief:**
1. Record a file list with SHA-256 for each file under the real `~/.claude/lessons`. The inbox may not exist yet.
2. Build a scratch copy of `plugins/warden` with one eval case, `evals/lesson-probe/`, whose prompt asks the agent to run `false` once as a Bash call.
3. Run `claude plugin eval <scratch>/warden --no-publish --ablation none --trust-plugin --keep-temp --allow-tools Bash --runs 1 --json <scratch>/r.json`.
4. Record the real inbox again and compare it with step 1.
5. Find the kept temp folder named in `r.json` and check what its `home/.claude/lessons/sessions/` holds.

The command bypasses `tests/behavior/run-behavior`, which normally adds `--no-publish`. This task therefore keeps the command in a shell variable and checks it before running it.

**Steps:**
- [ ] Put the step 3 command in a variable. Run `case " $CMD " in *" --no-publish "*) ;; *) echo "missing --no-publish"; exit 1 ;; esac` and see it pass. Only then run the command.
- [ ] Run the check and show both listings and the temp-home listing.
- [ ] If the real inbox changed, stop and report. Do not change the hook.
- [ ] Delete the kept temp folder named in `r.json`: run `chmod -R u+rwx` on it first, then `rm -rf`, then show that the path no longer exists. Delete the scratch copy the same way.
- [ ] Write the result into the PR body draft.

### Task 6: PR and handover

**Satisfies:** REQ-10 (the PR record)

**Files:** none.

**Depends on:** 5 and the final review

**Model:** session.

**Steps:**
- [ ] Write the PR body from the reconciled spec, with the Task 5 result.
- [ ] Push the branch and open the PR against `NicoSik/Warden_public` `main`.
- [ ] Hand over the merge command. After the merge, remind Nicolai to run `warden-lesson status` after a day of normal work (memory `lesson-capture-status-reminder`).

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 4 | Different files. Task 4 asserts the command path only. |
| 2 | 2 | It needs Task 1's helpers in the same script. |
| 3 | 3 | It needs Task 2's line formats in the same script. |
| 4 | 5 | Session check. It needs the script and the registration. |

After wave 4: the final review, the fix wave and the scoped re-review, then `reconciling-specs`, then Task 6.

## Requirement coverage

| REQ | Task |
|---|---|
| REQ-1 | 2 |
| REQ-2 | 2 |
| REQ-3 | 2 |
| REQ-4 | 3 |
| REQ-5 | 3 |
| REQ-6 | 1 |
| REQ-7 | 1 |
| REQ-8 | 4 |
| REQ-9 | 2 |
| REQ-10 | 5, 6 |
| REQ-11 | 3 |

## Risks, worst first

1. **Unscrubbed text reaches disk (Tasks 1 and 2).** `write_line` is the only writer and scrubs every string value. Tests plant secrets through both entry points, then grep the whole inbox. Task 1 carries the most risk.
2. **The hook slows or breaks sessions.** Both entries are async, the mode catches every exception, and the 50 ms median is tested. A broken script fails silently and costs no session time.
3. **Eval runs write to the real inbox.** Task 5 checks it before the PR. If it fails, the work stops.
4. **The read-order gate shifts.** No injected text changes. The hook prints nothing, and async hooks add no context, so agent behavior is unchanged. The next eval run will show it.
5. **Sequential waves on one script.** Tasks 1–3 share a file, so they run one after another. That costs wall time, not correctness.

Ruled out:
- Separate Python modules. `python3 -I` drops the script folder from `sys.path`, so sibling imports would need a path hack.
- Registering the hook in the repo's `settings.json`. Nicolai's live settings are a separate file, and the hook would never reach his sessions.
