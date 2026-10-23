# Spec: lesson-capture

Intent: `intent.md`. Date: 2026-10-23. Status: draft.

## Summary

This change adds a lesson inbox outside every repository. A hook in the `warden` plugin
writes a short line for each clear Bash failure and for each later pass of a failed test.
The command `warden-lesson` adds a lesson by hand and lists the inbox. Nothing triages the
lessons yet.

Size: 10 requirements from 23 intent items. The count is above the guide of about ten
because the storage, the scrub and the safety rules each carry their own proof. The change
is still one subsystem.

## Terms

- **The hook** is the lesson-capture command hook in `plugins/warden/hooks/hooks.json`.
- **The lesson script** is the one Python script in the `warden` plugin that runs the hook,
  `add` and `list`.
- **The inbox** is the folder `${WARDEN_LESSON_ROOT:-$HOME/.claude/lessons}`.
- **A session log** is `<inbox>/sessions/<session_id>.jsonl`.
- **The manual log** is `<inbox>/manual.jsonl`.
- **A line** is one JSON object on one line of a session log or the manual log.
- **The last simple command** is the text after the last `&&`, `||`, `;` or `|` of the
  command, without its leading spaces.
- **A test-like command** is a command whose last simple command matches the list in
  REQ-3.1.
- **The scrub** replaces every match of the secret patterns in REQ-7 with `<secret>`.

## Requirements

### Behavior

**REQ-1** The hook MUST write a `fail` line for each clear Bash failure.

- **REQ-1.1** The hook MUST read the exit code from the first line `Exit code N` of the
  `PostToolUseFailure` `error` field.
- **REQ-1.2** The hook MUST NOT write a line when `N` is 0, 130 or 143, or when
  `is_interrupt` is true.
- **REQ-1.3** The hook MUST NOT write a line for exit code 1 when the last simple command
  starts with `grep`, `rg`, `test`, `[`, `diff`, `cmp`, `pgrep`, `command -v`, `which` or
  `git diff --quiet`.
- **REQ-1.4** The hook MUST NOT write a line for a tool other than Bash on
  `PostToolUseFailure`.

*Proof: `tests/warden_lessons.sh` feeds synthetic payloads in the shape of the 2026-10-23
probe and asserts which payloads write a line.*
*Source: intent decision "Which failures count". Probe of 2026-10-23.*

**REQ-2** A `fail` line MUST hold only the fields below.

- **REQ-2.1** `cmd`: the basename of the first word of the last simple command. A second
  word follows when it matches `[a-z][a-z-]*`. The hook MUST cut the field to 40 characters.
- **REQ-2.2** `exit`: the exit code.
- **REQ-2.3** `sig`: the first output line after `Exit code N` that matches `error`,
  `fail`, `fatal`, `not found`, `denied`, `no such` or `cannot`, case-insensitive. When no
  line matches, `sig` MUST be the last non-empty output line. The hook MUST replace each
  path with `<path>`, apply the scrub, and cut the result to 120 characters.
- **REQ-2.4** The pointer: `session_id`, `transcript_path` and `tool_use_id` from the payload.
- **REQ-2.5** `repo`, `branch` and `commit`: the basename of the git top-level folder of
  `cwd`, its branch and its short commit. Each is empty when `cwd` is not in a git work tree.
- **REQ-2.6** `ts` (UTC, ISO 8601), `t` = `fail`, and `src` = `hook`.
- **REQ-2.7** `h`: for a test-like command only, the first 16 hex characters of the
  SHA-256 of the full command, a zero byte and `cwd`.
- **REQ-2.8** The line MUST NOT hold the full command text or any output line other than
  `sig`.

*Proof: `tests/warden_lessons.sh` asserts the exact key set and each field. A pytest-style
payload asserts that the header line does not become `sig`.*
*Source: intent constraints on records, the pointer and the error signature. Decision D2 of
2026-10-23.*

**REQ-3** The hook MUST record what fix linking needs, and nothing more.

- **REQ-3.1** A command is test-like when its last simple command starts with `pytest`,
  `py.test`, `jest`, `vitest`, `mocha`, `rspec`, `tox`, `python -m pytest`,
  `python -m unittest`, `python3 -m pytest`, `python3 -m unittest`, or with one of `npm`,
  `pnpm`, `yarn`, `bun`, `cargo`, `go`, `dotnet`, `mix`, `gradle`, `mvn` followed by `test`,
  or with `make test` or `make check`. A command is also test-like when it runs a `*.sh` file
  whose path holds a `tests/` or `test/` folder.
- **REQ-3.2** On `PostToolUse` for a test-like Bash command, the hook MUST write a `pass`
  line with `t`, `ts`, `tool_use_id` and `h` only.
- **REQ-3.3** On `PostToolUse` for Edit, Write, MultiEdit or NotebookEdit, the hook MUST
  write an `edit` line with `t` and `ts` only.
- **REQ-3.4** The hook MUST NOT write a `pass` line for a command that is not test-like.

*Proof: `tests/warden_lessons.sh` asserts the key sets of `pass` and `edit` lines and the
test-like list case by case.*
*Source: decision of 2026-10-23 "pass and edit events store no command text".*

**REQ-4** `warden-lesson list` MUST derive one record per failure kind per session.

- **REQ-4.1** The dedupe key MUST be `cmd`, `exit` and `sig` with every digit run replaced
  by `N`. The record MUST show the `sig` of the first line with its digits kept, and a
  `count` of the lines that share the key.
- **REQ-4.2** A record MUST show `fixed = true` when a later `pass` line in the same session
  log has the same `h`. It MUST then show that `pass` line's `tool_use_id` and the number of
  `edit` lines between the last matching `fail` line and that `pass` line.
- **REQ-4.3** `list` MUST print the records of all session logs and the manual log, newest
  first. Each row MUST show the date, `src`, `repo`, `cmd`, `sig` or the lesson text,
  `count` and `fixed`.
- **REQ-4.4** `list --json` MUST print the same records as JSON lines.
- **REQ-4.5** `list` MUST skip a line that is not valid JSON.

*Proof: `tests/warden_lessons.sh` covers a repeated failure, two failures that differ only in
numbers (one record, count 2), a fixed test with two edits, a plain rerun (0 edits), and a
corrupt line.*
*Source: intent decisions on dedupe and fix linking. Decision D2 of 2026-10-23 (digit runs).*

**REQ-5** `warden-lesson add` MUST record one lesson line in the manual log.

- **REQ-5.1** `warden-lesson add "<text>"` MUST write `t` = `lesson`, `ts`, `src`, `text`,
  `repo`, `branch` and `commit`.
- **REQ-5.2** `src` MUST be `user`, or `agent` when the command gets `--by agent`.
- **REQ-5.3** The command MUST apply the scrub to `text` and cut it to 200 characters.
- **REQ-5.4** The command MUST add `session_id` when the environment names the session.
- **REQ-5.5** The command MUST exit 2 with a usage line when `text` is empty or missing.

*Proof: `tests/warden_lessons.sh` runs `add` with and without `--by agent`, with a planted
secret, with 300 characters and with no text.*
*Source: intent decision on `warden-lesson add`. Decision of 2026-10-23 (source field).*

### Data

**REQ-6** The lesson script MUST write lines safely and only in the inbox.

- **REQ-6.1** The lesson script MUST write only under the inbox. It MUST create the inbox
  and `sessions/` with mode 700, and files with mode 600.
- **REQ-6.2** The lesson script MUST apply the scrub and the caps before a line reaches
  disk.
- **REQ-6.3** A line MUST be at most 512 bytes. The lesson script MUST write each line with
  one write call on a file opened with O_APPEND.
- **REQ-6.4** When the inbox is inside a git work tree, the lesson script MUST NOT write.

*Proof: `tests/warden_lessons.sh` checks modes, the 512-byte cap with long inputs, and an
inbox placed inside a temporary git repository.*
*Source: intent constraints "outside every repository" and "Every stored text field passes
the secret scrub". Decision of 2026-10-23 (scrub and caps at write time).*

**REQ-7** The scrub MUST cover at least every secret shape that `hooks/guard-secrets.sh`
detects.

- **REQ-7.1** The scrub MUST also cover GitHub tokens (`gh[pousr]_…`), Anthropic and OpenAI
  style keys (`sk-…`), Slack tokens (`xox[abpr]-…`), `Bearer` and `Authorization:` values,
  and `password=`, `token=`, `secret=` and `api_key=` values.
- **REQ-7.2** The scrub MUST run on every text field of every line.

*Proof: `tests/warden_lessons.sh` plants each shape in failure output and in `add` text, then
greps the whole inbox for each planted value and finds none. A second check reads the shapes
from `hooks/guard-secrets.sh` and asserts that the scrub replaces a sample of each.*
*Source: intent constraint "Every stored text field passes the secret scrub".*

### Interface

**REQ-8** The `warden` plugin MUST deliver the hook, and `bin/` MUST deliver the command.

- **REQ-8.1** `plugins/warden/hooks/hooks.json` MUST register the hook on
  `PostToolUseFailure` with matcher `Bash`, and on `PostToolUse` with matcher
  `Bash|Edit|Write|MultiEdit|NotebookEdit`. Both entries MUST set `async: true`.
- **REQ-8.2** `bin/warden-lesson` MUST run the lesson script from the plugin in the same
  repository.
- **REQ-8.3** The existing `SessionStart` and `SubagentStart` entries MUST stay unchanged.

*Proof: `tests/warden_hooks.sh` asserts the new entries and the unchanged ones.
`tests/warden_lessons.sh` runs `bin/warden-lesson`.*
*Source: intent "Affected users and systems" (reaches sessions without `install.sh`).*

### Operations

**REQ-9** The hook MUST never disturb a session.

- **REQ-9.1** The hook MUST exit 0 and print nothing on stdout and stderr in every case.
- **REQ-9.2** When `WARDEN_LESSON_OFF` is `1`, the hook MUST exit before it reads stdin.
- **REQ-9.3** A failed write MUST be silent.
- **REQ-9.4** The median run time of the hook over 20 `fail` payloads MUST be under 50 ms.
- **REQ-9.5** At most once a day, the lesson script MUST delete session logs whose last
  change is more than 30 days old. It MUST NOT delete the manual log.

*Proof: `tests/warden_lessons.sh` covers a read-only inbox, invalid JSON on stdin, the off
switch, the timing check and back-dated session logs.*
*Source: intent constraints on blocking, 50 ms, the off switch and silent failure. Decision
of 2026-10-23 (30-day retention).*

**REQ-10** An eval run MUST NOT write to Nicolai's real inbox.

- **REQ-10.1** The first eval run after this change MUST record the file list and hashes of
  the real inbox before and after the run, and show that they are equal.
- **REQ-10.2** The same check MUST show that the eval's temporary home holds session logs
  from the run.

*Proof: the PR body records both checks.*
*Source: intent measure "In an eval run, the capture hook writes only inside the eval's
temporary HOME".*

## Non-goals

- Triage, grouping across sessions, ranking or proposals (P3).
- Linking a fix that a different command verified. This is a known limit.
- Telling the agent that `warden-lesson add` exists. It runs it only when told (decision of
  2026-10-23).
- Any change to cleanup settings or to the SessionStart text.

## Constraints applied

Rules and area guides:

- `CLAUDE.md` (root): test first, a pass-or-fail check for every change, reuse before you
  create. REQ-7 reuses the secret shapes of `hooks/guard-secrets.sh` through a coverage
  test, because the plugin cannot read `hooks/lib` in the merged eval arm.
- `bin/warden-handoff`: stores its files outside every repository under `~/.claude/`. The
  inbox follows the same pattern.
- `tests/no_machine_content.sh`: no machine path in any committed file.
- The `2026-10-warden-plugin-full-merge` change: the merged eval arm copies every `warden`
  file, so the hook reaches eval arms with no harness change.

Policy skills: this is a configuration and tooling repository with no domain. The scrub is
a privacy measure that the intent requires, not a policy skill.

## Open questions carried from intent

- **Answered.** The payload fields: REQ-1 and REQ-3 use `PostToolUseFailure` with the
  `Exit code N` first line and `PostToolUse` for successes, from the hooks reference and
  the probe of 2026-10-23.
- **Answered.** Test-like commands: REQ-3.1.
- **Answered.** Path, format, size cap and parallel writes: REQ-6.
- **Still open, answered in the plan.** How `add` learns the session ID inside a session
  (REQ-5.4). The plan's first task checks which environment variable Claude Code sets for
  Bash calls.
- **Still open, answered by REQ-10.** Whether `claude plugin eval` sets `HOME` to its
  temporary folder.
