# Setup-check nudge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remind the main agent once to run the Graphify setup check for a repository that the session created, as soon as that repository has enough code.

**Architecture:** A bash prefilter, `plugins/warden/hooks/setup-nudge`, runs synchronously on every PostToolUse Bash and Skill call. It exits at once unless the raw payload holds a trigger word or a marker waits. On a hand-off it runs a new `nudge` subcommand of `plugins/warden/scripts/warden-lesson`. The subcommand keeps per-session state in `~/.claude/warden/nudge/` and runs `graphify-setup status` at the triggers. It prints the nudge as `additionalContext` and writes `nudge` and `setup-call` lines with the existing `write_line`.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), Python 3 standard library only (`python3 -I`), git, `jq` in tests.

**Spec:** `docs/superpowers/changes/2026-11-setup-check-nudge/spec.md` (approved, commit `7f4eaac`). Intent: `intent.md` in the same folder.

## Global Constraints

- The nudge hook exits 0 on every path, and a slow or failed check prints nothing (REQ-9.1, REQ-9.2).
- Time limits: `git rev-parse` 1 second each, a status check 3 seconds each, all status checks of one run 4 seconds in total, hook `"timeout": 5` (REQ-9.3, REQ-8.1).
- Fast path: median CPU time (user + sys) of 20 runs under 20 ms. A `git commit` in a repository that is not pending: under 100 ms (REQ-10).
- Records never contain a filesystem path or any command text (REQ-6.5).
- Repository ID: basename, `#`, first 8 hex characters of SHA-256 of the resolved `git rev-parse --git-common-dir` (spec Terms).
- State lives in `~/.claude/warden/nudge/`. Cleanup removes state files, markers and claimed markers older than 7 days (REQ-7).
- No committed file holds a machine path (`tests/no_machine_content.sh`).
- `plugins/warden/hooks/setup-check.md` and the SessionStart output of `plugins/warden/hooks/code-map` do not change (REQ-5.3).
- The async lesson-capture entries in `hooks.json` do not change (REQ-8.3).
- Off switch: `WARDEN_NUDGE_OFF=1` (REQ-8.4).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `plugins/warden/hooks/setup-nudge.md` | Nudge template, `{{REPO}}` and `{{GRAPHIFY_SETUP}}` once each, two variant lines | 2 |
| `plugins/warden/scripts/warden-lesson` | New `nudge` subcommand: state, triggers, status, delivery, records. Later: the Nudges section of `report` | 3, 5 |
| `tests/warden_setup_nudge.sh` | Offline tests T1–T12 and T14–T18 for the `nudge` subcommand | 3 |
| `plugins/warden/hooks/setup-nudge` | Bash prefilter | 4 |
| `plugins/warden/hooks/hooks.json` | The new synchronous PostToolUse entry | 4 |
| `tests/warden_nudge_fastpath.sh` | T13, the timing test, the prefilter hand-off checks | 4 |
| `tests/warden_hooks.sh` | T19: the PostToolUse assertion grows to allow the new entry | 4 |
| `tests/warden_lessons.sh` | Report tests for the Nudges section | 5 |
| `docs/decisions/RULES-AND-HOOKS.md` | One row for the new hook | 6 |

---

### Task 1: Probe the hook payload fields live

**Satisfies:** REQ-11

**Files:**
- Change: `docs/superpowers/changes/2026-11-setup-check-nudge/plan.md` (the "Probe results" section at the end)

**Depends on:** none

**Model:** session

**Brief:** Record P1, P2 and P3 before any code relies on them. Use a temporary folder under the scratchpad, a settings file in that folder, and `claude -p --settings <file>`. Never edit `~/.claude/settings.json`. The temporary hook is a PostToolUse command hook with matcher `Bash|Skill` that appends its stdin to `payloads.jsonl` in the temporary folder. The prompt asks for three actions: run `echo main` with Bash, invoke one Skill, and dispatch one `general-purpose` subagent with model `sonnet` that runs `echo sub` with Bash. Read `payloads.jsonl` with `jq` and record:
- P1: whether `agent_id` is present in the subagent's Bash payload and absent in the main session's Bash payload.
- P2: whether the Skill payload names the skill, and in which field (`tool_input.skill` expected).
- P3: whether the subagent payload's `session_id` equals the main session's.

Record the exact field names and one redacted example payload per call. If P1 or P3 fails, stop and report to Nicolai (decision D-c). If P2 fails, continue: REQ-2.6 applies, and the code in Task 3 already handles a payload without a skill name.

**Steps:**
- [ ] Write the temporary settings file and the capture hook in the scratchpad.
- [ ] Run the headless session with the three actions.
- [ ] Read the payloads and answer P1, P2 and P3.
- [ ] Write the results into "Probe results" below and commit as `docs: record the payload probe for the setup-check nudge`.

### Task 2: Write the nudge template

**Satisfies:** REQ-4

**Files:**
- Create: `plugins/warden/hooks/setup-nudge.md`

**Depends on:** none

**Model:** cheap tier — one new text file. The brief gives its full content.

**Interfaces:**
- Produces: the template with exactly one `{{REPO}}`, exactly one `{{GRAPHIFY_SETUP}}`, and two lines that start `skill: ` and `commit: `. Task 3 keeps the line for its variant, drops the other one, and removes the `skill: ` or `commit: ` prefix.

**Brief:** The template holds this text, with no other content:

~~~~
**Setup check for a new repository.** This session created the repository in the command below, and it now has enough code for a code graph.
skill: Run the setup check for it before the first code exploration in this skill:
commit: Run the setup check for it before your next code exploration in that repository, or before you dispatch the next subagent into it, whatever skill is running:

```bash
cd {{REPO}} && {{GRAPHIFY_SETUP}} status
```

Act on the printed word as the Setup check section of the session context says.
~~~~

The placeholders have no quotes around them, because Task 3 inserts `shlex.quote` output. The text names no status word (REQ-4.5). Check: `python3 plugins/superpowers/skills/asd-ste100/scripts/ste-lint.py plugins/warden/hooks/setup-nudge.md` shows 0 hard violations, and `grep -c '{{REPO}}'` and `grep -c '{{GRAPHIFY_SETUP}}'` each print 1.

**Steps:**
- [ ] Create the file with the text above.
- [ ] Run the lint and the two `grep -c` checks, and show the output.
- [ ] Commit as `feat: add the setup-check nudge template`.

### Task 3: Add the `warden-lesson nudge` subcommand

**Satisfies:** REQ-1, REQ-2, REQ-3, REQ-5, REQ-6, REQ-7, REQ-9

**Files:**
- Change: `plugins/warden/scripts/warden-lesson` (new functions after `_hook`, new `nudge` parser beside `hook` in `main`)
- Test: `tests/warden_setup_nudge.sh` (new, sourced through `tests/lib/harness.sh` like `tests/warden_lessons.sh`)

**Depends on:** 1, 2

**Model:** standard tier — the task crosses the script, the template and a new test file.

This task resists decomposition. State, triggers, delivery and records share one state file and one lock, and each test case runs the whole subcommand.

**Interfaces:**
- Consumes: `plugins/warden/hooks/setup-nudge.md` from Task 2. Existing `write_line(path, obj)`, `inbox()`, `parse_chain(command)`, `_now()`.
- Produces: `warden-lesson nudge` reads one hook payload on stdin, prints at most one JSON object `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"}}` on stdout, and exits 0. Task 4 calls it as `python3 -I "<plugin root>/scripts/warden-lesson" nudge`.
- Produces: the state paths `~/.claude/warden/nudge/<sid>.json`, `<sid>.ready`, `<sid>.lock` and `<sid>.claimed.<pid>`, where `<sid>` is `session_id` with every character outside `[A-Za-z0-9_-]` removed. Task 4's prefilter tests for `<sid>.ready`.
- Produces: records `{"t":"nudge","ts","repo","trigger","via","word"}` and `{"t":"setup-call","ts","repo"}` in `<inbox>/sessions/<sid>.jsonl`. Task 5 reads them.

**Brief:** Build the subcommand from these rules. Every rule cites its requirement.
- **Payload.** Parse stdin as JSON. On bad JSON, a non-object or an empty `session_id`, exit 0 silently (REQ-9.5). A payload with `agent_id` is a subagent call. Use the field names that Task 1 recorded.
- **Plugin root.** The plugin root is the parent of the script's folder. The setup script is `<plugin root>/scripts/graphify-setup`, and the template is `<plugin root>/hooks/setup-nudge.md`.
- **Call folder.** Take the path of a leading `cd <path> &&` (the first simple command of `parse_chain`, joined by `&&`). For a `git -C <path> …` simple command, take `<path>`. Otherwise take the payload `cwd`. Resolve a relative path against `cwd`.
- **Repository ID.** `git -C <dir> rev-parse --path-format=absolute --git-common-dir` with a 1-second timeout, resolved with `os.path.realpath`. The ID is `basename(toplevel) + "#" + sha256(common_dir)[:8]`.
- **Session start.** `os.stat(transcript_path).st_birthtime`. If it or a `.git` birthtime is missing, mark nothing (REQ-1.5).
- **Create trigger (REQ-1).** A simple command whose words start with `git init`, `git clone`, `create-next-app`, `npm create`, `pnpm create`, `yarn create`, `bun create`, `npx create-…`, `cargo new`, `cargo init` or `uv init`. Check the toplevel of the call folder and each direct subdirectory that has a `.git`. Mark a repository pending only if its `.git` birthtime is later than the session start. This runs in main-session and subagent calls.
- **Commit trigger (REQ-2.1).** A simple command `git commit` or `git -C <path> commit`, in a pending repository that is not nudged. Run the status check for that repository. This runs in main-session and subagent calls.
- **Skill trigger (REQ-2.2, REQ-2.6).** A main-session Skill call triggers when its skill name is brainstorming, writing-specs, writing-plans or systematic-debugging. Ignore any `namespace:` prefix. A Skill payload that names no skill also triggers. Run the status check for every pending repository of the session.
- **Status check.** Run `<setup script> status` with `cwd` = the repository toplevel, a 3-second timeout, and a shared budget of 4 seconds per run. A repository that the budget did not reach stays pending. `small` keeps it pending. `ready` or `declined` moves it to `dropped`. `ask`, `build` or `no-cli` makes it due. Any other output or a timeout keeps it pending (REQ-2.3 to REQ-2.5, REQ-9.2, REQ-9.3).
- **Delivery (REQ-3).** In a main-session call, the run delivers a due repository at once (`via` = `direct`). In a subagent call, the run adds a due repository to `<sid>.ready` and prints nothing. Its later delivery has `via` = `marker`. A main-session call claims `<sid>.ready` with `os.rename` to `<sid>.claimed.<pid>`, delivers its repositories, then removes the claimed file. Only the run whose rename succeeds delivers. A delivered repository moves to `nudged`. Combine all repositories of one call into one message (REQ-3.5). The `skill` variant applies to the Skill trigger. The `commit` variant applies to the commit trigger and to every marker delivery.
- **Rendering (REQ-4.1, REQ-4.6).** Read the template. If `{{REPO}}` or `{{GRAPHIFY_SETUP}}` does not appear exactly once, print nothing and keep the repository pending. Insert `shlex.quote(toplevel)` and `shlex.quote(setup script)`. Keep the line of the variant without its `skill: ` or `commit: ` prefix, and drop the other line. Join several repositories as several blocks in one message. Serialize with `json.dumps`.
- **Records (REQ-6).** After each delivery, write a `nudge` line with `write_line`. For each Bash call whose command runs `graphify-setup`, in main-session and subagent calls, write a `setup-call` line whose `repo` is the repository ID of the call folder. Records hold no path and no command text. `write_line` already returns `False` when lesson capture is off. Ignore that result, so the nudge still works (REQ-6.6).
- **State (REQ-7).** `<sid>.json` holds `{"pending": {id: toplevel}, "nudged": [id], "dropped": [id]}`. Take `fcntl.flock` on `<sid>.lock` around every read-modify-write. Write to a temporary file and `os.replace` it. Create the folder with mode 700. On each state write, remove files in the folder older than 7 days, including `*.claimed.*`.
- **Safety (REQ-9).** Wrap the whole run in `try/except BaseException`, as `_hook` does. Build the output string first and print it once at the end. Exit 0.

Tests in `tests/warden_setup_nudge.sh`. Each test sets a temporary `HOME`, `WARDEN_LESSON_ROOT`, a temporary transcript file created before the repositories, and `PATH` with `tests/behavior/stubs` first so `graphify` exists. Source files are 20 committed `.py` files, which makes the real status `ask`. Each test asserts:
- T1: `git init` in `cwd` marks the repository pending. A Skill payload for `writing-plans` while it is `small` prints nothing. After 20 committed source files, the same Skill payload prints one `skill`-variant nudge. A third Skill payload prints nothing.
- T2: a payload with `cwd` = the parent folder and `npx create-next-app app && cd app && git init` (create the repo in the test first) marks `app` pending. A Skill payload from the parent folder nudges `app`.
- T3: the test creates a repository before the transcript file. The hook never marks it, and a later commit or Skill payload prints nothing.
- T4: `git commit` in the main session while `small` prints nothing. After 20 source files, `git commit` prints one `commit`-variant nudge.
- T5: `git commit` with `agent_id` prints nothing and creates `<sid>.ready`. Then a main-session `ls` payload prints the nudge with the `commit` variant, and `<sid>.ready` is gone. A second `ls` payload prints nothing.
- T6: a Skill payload with `agent_id` prints nothing and creates no marker.
- T7: first after `graphify-setup decline`, then after `ready` from a stub `graphify-out/`. In both cases a commit and a Skill payload print nothing. The state lists the repository under `dropped`.
- T8: with `graphify` absent from `PATH`, the status is `no-cli`, and a commit prints one nudge.
- T9: a session whose transcript is newer than an existing repository runs `ls`, `git commit` and a `writing-plans` Skill payload inside it. Nothing prints, and no marker exists.
- T10: `cd "<repo>" && "<setup>" status` from the parent folder writes one `setup-call` line with that repository's ID. The same command with `agent_id` writes one more. A command without `cd` uses `cwd`. No line contains the repository path or the word `status`.
- T11: exactly one `nudge` line, with fields `ts`, `repo`, `trigger`, `via`, `word`. `repo` matches `^[^#/]+#[0-9a-f]{8}$`. `trigger` is `skill` or `commit`. `via` is `direct` or `marker`. The line holds no `path` field and no full repository path.
- T12: (A) a repository at `<tmp>/my "odd" repo`: `shlex.split` of the command line in the nudge gives `cd`, that path, `&&`, the setup script path and `status`. The output parses as JSON. (B) A template copy without `{{REPO}}`. (C) A copy with `{{REPO}}` twice. (D) A copy without `{{GRAPHIFY_SETUP}}`, then a copy with it twice. In B, C and D the run prints nothing and exits 0. The repository stays pending. Point the subcommand at the copy by running a copied plugin tree.
- T14: a copied plugin tree holds a stub `graphify-setup` that sleeps 10 seconds. The run ends within 5 seconds with exit 0 and no output. The repository stays pending.
- T15: two main-session runs started together against one `<sid>.ready` print exactly one nudge between them.
- T16: the next state write removes state files, markers and `*.claimed.*` files with an mtime 8 days old. Current files stay.
- T17: bad JSON, a JSON list, and a payload without `session_id` each exit 0 with no output.
- T18: with `WARDEN_LESSON_OFF=1`, T4's commit still prints the nudge, and the session log does not exist.

Test command: `bash tests/warden_setup_nudge.sh`.

**Steps:**
- [ ] Write T17 and T1, run them, and see them fail because the `nudge` subcommand does not exist.
- [ ] Add the `nudge` parser and the payload, call-folder, repository-ID and state helpers. Implement the create and Skill triggers, the status check and direct delivery.
- [ ] Run T17 and T1 and see them pass.
- [ ] Write T2, T3, T6, T7, T8 and T9, and see the new ones fail where behaviour is missing.
- [ ] Implement the remaining create-trigger and drop rules, and see them pass.
- [ ] Write T4, T5 and T15, and see them fail.
- [ ] Implement the commit trigger, the marker and the claim by rename, and see them pass.
- [ ] Write T10, T11, T12 and T18, and see them fail.
- [ ] Implement rendering and the records, and see them pass.
- [ ] Write T14 and T16, and see them fail.
- [ ] Implement the time budget and cleanup, and see them pass.
- [ ] Run `bash tests/warden_setup_nudge.sh` and `bash tests/warden_lessons.sh`, and show the output.
- [ ] Commit as `feat: add the warden-lesson nudge subcommand`.

### Task 4: Add the bash prefilter and register the hook

**Satisfies:** REQ-8, REQ-10

**Files:**
- Create: `plugins/warden/hooks/setup-nudge` (mode 755)
- Change: `plugins/warden/hooks/hooks.json` (one new entry in the `PostToolUse` array, after the existing entry)
- Change: `tests/warden_hooks.sh:150-160` (the PostToolUse loop)
- Test: `tests/warden_nudge_fastpath.sh` (new)

**Depends on:** 3

**Model:** standard tier — the task crosses a new script, `hooks.json` and two test files.

**Interfaces:**
- Consumes: `python3 -I "<plugin root>/scripts/warden-lesson" nudge`, which reads the payload on stdin and prints at most one JSON object. The marker path `~/.claude/warden/nudge/<sid>.ready`.

**Brief:** The prefilter is a bash script without `set -e`. In order:
1. If `WARDEN_NUDGE_OFF` is `1`, exit 0.
2. Read stdin into a variable.
3. Take `session_id` with a bash regex (`"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"`), and remove every character outside `[A-Za-z0-9_-]`. If it is empty, exit 0.
4. If the payload has no `"agent_id"` key and `$HOME/.claude/warden/nudge/<sid>.ready` exists, hand off.
5. Else, if the payload holds a trigger word, hand off. The trigger words are `git init`, `git clone`, `git commit`, `git -C`, `create-next-app`, `npm create`, `pnpm create`, `yarn create`, `bun create`, `npx create-`, `cargo new`, `cargo init`, `uv init` and `graphify-setup`. A `"tool_name"` key with the value `"Skill"` also triggers, with optional spaces around the `:`.
6. Else, exit 0.

To hand off, pipe the saved payload to the subcommand, pass its stdout through, and exit 0 whatever its status. The plugin root is the parent of the script's folder, as in `hooks/code-map`.

`hooks.json` gets this entry, appended to the `PostToolUse` array:
`{"matcher": "Bash|Skill", "hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/setup-nudge\"", "shell": "bash", "async": false, "timeout": 5}]}`

In `tests/warden_hooks.sh`, change the PostToolUse check. It asserts that the lesson entry is present and unchanged. It also asserts that the only other entry is the nudge entry above. The PostToolUseFailure check stays exact. The five-event check stays. The old assertion grows and does not get weaker: any other change to the lesson entry still fails.

Tests in `tests/warden_nudge_fastpath.sh` assert:
- T13: with `WARDEN_NUDGE_OFF=1`, a commit payload that would nudge prints nothing. The run creates no state folder.
- Hand-off: in a stub plugin tree, `warden-lesson` only writes a flag file. `ls` with no marker does not hand off. `git commit` hands off. A main-session `ls` with a marker hands off. A subagent `ls` with a marker does not.
- Timing (REQ-10.1): the median CPU time of 20 prefilter runs on an `ls` payload is under 20 ms. CPU time is user + sys, from `resource.getrusage(RUSAGE_CHILDREN)` differences around each run.
- Timing (REQ-10.2): the median CPU time of 20 runs on a `git commit` payload in a repository that is not pending is under 100 ms.
- T19 lives in `tests/warden_hooks.sh`: the new entry is synchronous, has matcher `Bash|Skill` and `"timeout": 5`, and the lesson entries are byte-equal to before.

Test commands: `bash tests/warden_nudge_fastpath.sh` and `bash tests/warden_hooks.sh`.

**Steps:**
- [ ] Write the hand-off tests, T13 and the two timing tests, and see them fail because the script does not exist.
- [ ] Write the prefilter, and see those tests pass.
- [ ] Change the PostToolUse check in `tests/warden_hooks.sh` and add T19, and see T19 fail.
- [ ] Add the `hooks.json` entry, and see `tests/warden_hooks.sh` pass.
- [ ] Run `bash tests/run.sh`, and show the output.
- [ ] Commit as `feat: register the setup-check nudge hook`.

### Task 5: Show nudges and setup calls in `warden-lesson report`

**Satisfies:** REQ-6, REQ-11

**Files:**
- Change: `plugins/warden/scripts/warden-lesson` (`_report`, and a helper beside `report_rows`)
- Test: `tests/warden_lessons.sh` (new cases after the existing report cases)

**Depends on:** 3

**Model:** cheap tier — one production file, with behaviour and tests stated below.

**Interfaces:**
- Consumes: records `{"t":"nudge","ts","repo","trigger","via","word"}` and `{"t":"setup-call","ts","repo"}` in session logs.
- Produces: `nudge_rows()` returns a list of dicts `{"ts", "repo", "trigger", "via", "word", "followed": bool}`, newest first.

**Brief:** `report` gets a "Nudges:" section after the lessons section, which the report prints only when a nudge line exists. Each row shows the date, the repository ID, the trigger, the via value, the word, and `setup-call` or `no setup-call`. A nudge counts as followed when the same session log holds a `setup-call` line for the same `repo` with a later `ts`. The section is read-only, and `list` does not change. Tests assert:
- A session log with a `nudge` and then a matching `setup-call` shows one row ending in `setup-call`.
- A `setup-call` for another repository, or one before the nudge, shows `no setup-call`.
- With no `nudge` line, the report output is byte-equal to the output before this change.
- `list --json` output does not change when a log holds `nudge` and `setup-call` lines.

Test command: `bash tests/warden_lessons.sh`.

**Steps:**
- [ ] Write the four tests, and see the first two fail.
- [ ] Add `nudge_rows()` and the section, and see all four pass.
- [ ] Run `bash tests/warden_lessons.sh`, and show the output.
- [ ] Commit as `feat: show nudges and setup calls in the lesson report`.

### Task 6: Document the hook

**Satisfies:** REQ-8

**Files:**
- Change: `docs/decisions/RULES-AND-HOOKS.md` (one row in the Hooks table, and the "Wired now" line)

**Depends on:** none

**Model:** cheap tier — one documentation file, with content stated below.

**Brief:** Add a row with hook `setup-nudge`, event `PostToolUse Bash|Skill`, blocks `report` and status `wired 2026-11`. The function text is: "Reminds the main agent once to run the setup check for a new repository. The repository needs 20 or more source files first. Silent for repositories older than the session." Check: `python3 plugins/superpowers/skills/asd-ste100/scripts/ste-lint.py docs/decisions/RULES-AND-HOOKS.md` shows no new hard violation against the current file.

**Steps:**
- [ ] Add the row.
- [ ] Run the lint before and after, and show both outputs.
- [ ] Commit as `docs: list the setup-check nudge hook`.

### Task 7: Hand over the behaviour reruns and prepare the PR test plan

**Satisfies:** REQ-11

**Files:** none committed. A temporary arms file in the scratchpad.

**Depends on:** 3, 4, 5, 6

**Model:** session

**Brief:** Write an arms file with three rows, `setup-quick-question`, `setup-planning` and `read-order`, each with baseline `a0f4807` (`main`) and candidate = the branch head SHA. Use the direction and count of the same rows in `tests/behavior/evals/arms.conf`. Give Nicolai the exact `tests/behavior/run-behavior --arms <file>` command to start himself (decision D12). The PR body test plan lists:
- `tests/run.sh` result.
- The probe results from Task 1.
- The three behaviour cases with no change against `main`.
- The post-merge live check (REQ-11.3). Start a session in `~/Documents/Projects`, create a repository, and commit 20 or more source files. Check that the nudge arrives. Check that `warden-lesson report` shows the nudge with `setup-call`.

**Steps:**
- [ ] Write the arms file with real SHAs.
- [ ] Hand Nicolai the command block.
- [ ] Draft the PR test plan with the four items above.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2, 6 | Each owns a different file. Task 1 writes only the Probe results section of `plan.md`. |
| 2 | 3 | It needs the probe field names from Task 1 and the template from Task 2. |
| 3 | 4, 5 | Both depend on Task 3. Task 4 owns the prefilter, `hooks.json`, `tests/warden_hooks.sh` and `tests/warden_nudge_fastpath.sh`. Task 5 owns `warden-lesson` and `tests/warden_lessons.sh`. |
| 4 | 7 | It needs the finished branch head. |

After the last wave: the final review, the fix wave and the scoped re-review, then `reconciling-specs`. After the merge: remove `~/.claude/projects/-Users-nicol-Documents-Projects/memory/graphify-setup-check.md` and its `MEMORY.md` line.

## Requirement coverage

| Requirement | Task |
|---|---|
| REQ-1 pending repositories | 3 |
| REQ-2 triggers | 3 |
| REQ-3 delivery | 3 |
| REQ-4 nudge text | 2, 3 |
| REQ-5 existing repositories unchanged | 3 (T3, T9), 7 (`setup-quick-question`) |
| REQ-6 records | 3, 5 |
| REQ-7 state | 3 |
| REQ-8 registration | 4, 6 |
| REQ-9 safety | 3 |
| REQ-10 cost | 4 |
| REQ-11 live checks | 1, 5, 7 |

## Risks, worst first

1. **A slow synchronous hook delays every Bash call (Task 4).** The prefilter runs on every Bash and Skill call of every session. A slip, such as starting Python on the fast path, costs about 40 ms per call. The timing test and the hand-off test catch this. This is the task with the most risk.
2. **A nudge in an existing repository (Task 3).** That would break the SessionStart rule that Nicolai's sessions rely on. T3, T9 and the `setup-quick-question` rerun cover it.
3. **A lost or doubled nudge between subagent and main session (Task 3).** Parallel hook runs race on the state and the marker. T5 and T15 cover the lock and the claim by rename.
4. **`st_birthtime` is missing on a filesystem.** The hook then marks nothing, so it fails silent rather than noisy. Ruled acceptable by REQ-1.5.
5. **Grown assertion in `tests/warden_hooks.sh` (Task 4).** The PostToolUse check changes from "exactly one entry" to "the lesson entry unchanged plus the nudge entry". The new check still fails on any change to the lesson entry.

Ruled out:
- A separate Python script for the nudge. It would duplicate `write_line` and the session path (decision A1).
- Reusing `warden-lesson hook` synchronously. That would put lesson capture on the synchronous path (decision A1).
- A new behaviour case for a repository created mid-session. The offline tests T1–T5 cover it (spec Non-goals).

## Probe results

Not yet run. Task 1 writes this section.
