# Rerunnable Behavior Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command, `tests/behavior/run-behavior`, reruns the Graphify trigger scenarios as isolated `claude -p` agents against a baseline and a candidate commit of the skills, and grades each run from side effects.

**Architecture:** A Bash runner turns each arm (a git commit) into a scratch copy of the Superpowers plugin with a logging shim, copies a fixture repo per rep, and launches one `claude -p` child per rep in a scratch `HOME` and `CLAUDE_CONFIG_DIR`. Graders read the shim log, the repo's git config and the `stream-json` tool-call events, never the agent's prose. A run record with pinned versions goes into the change directory, and raw output stays in the cache, outside every repo.

**Tech Stack:** Bash 3.2-compatible shell, git, `claude` CLI 2.1.305 (`-p --output-format stream-json`), Graphify CLI 0.9.92, macOS `security` for the Keychain, Python 3 (`-I`) for JSON parsing only.

**Spec:** `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/intent.md` (bounded change, no spec)

## Global Constraints

- No quorum. Local harness only.
- A run never touches a real project, the real `~/.claude`, or Warden's own git state.
- Graphify missing: the run stops before any agent starts.
- The token lives in the macOS Keychain, service `warden-behavior-oauth`, account `$USER`.
- The token is passed only to the `claude` child process, never in any argv.
- The token is never written to disk inside a scratch directory.
- Every agent runs with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`.
- The runner refuses to start (exit 3) when `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set in its own environment. Both outrank the OAuth token, so a set key would silently bill another account. The child environment never contains either.
- Transcripts and run records are scanned for the token. A hit is removed, and the run fails with exit code 4. The message then tells Nicolai to revoke the token:
  - Sign out of all sessions in claude.ai under Settings > Account. A token listed under Settings > Claude Code can also be removed there.
  - Delete the Keychain item with `security delete-generic-password -a "$USER" -s warden-behavior-oauth`.
  - Create a new token.
- The two real token guarantees are the env-scrub probe and the leak scan. The `Bash(security:*)` deny rule and the sandbox only catch accidental access. They do not stop a determined agent, which could, for example, call the Keychain through another binary.
- Each scenario runs inside Claude Code's Bash sandbox (`SANDBOX=on`) unless Task 7 shows the sandbox breaks its grading. The child settings hold:
  - `sandbox.enabled: true`
  - `allowUnsandboxedCommands: false`
  - `failIfUnavailable: true`
  - `credentials.envVars` deny entries for `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`
  - `filesystem.denyRead` on the real home directory, with `allowRead` for the Graphify install and its Python
  - `filesystem.allowWrite` for the run directory and the scratch cache
  - no allowed network domains
  The docs say the sandbox write-protects `.git/config` and `.git/hooks` in the working directory. So `graphify-setup decline` may fail inside it, and Task 7 checks this. A scenario that cannot be graded sandboxed runs with `SANDBOX=off`, and its record carries the risk statement from risk 2.
- Token setup runs in a separate terminal, never inside a Claude Code session, so the token never enters a session transcript.
- A run prints its cost (agent count, model, token range) and waits for `y` before starting. `--yes` skips the prompt; only the offline test uses it.
- Every run record pins: `claude --version`, the model ID from the stream, each arm's commit SHA, `graphify --version`, and the fixture's tree hash.
- Default model: none passed (the account default). `--model <id>` overrides it. Default reps: 5.
- Grading reads side effects only: shim log, git config, work-tree status, and `stream-json` tool-call events.
- Raw output goes to `${XDG_CACHE_HOME:-$HOME/.cache}/warden-behavior/runs/<run-id>/`. Committed records hold no absolute home path, so `tests/no_machine_content.sh` stays green.
- `tests/run.sh` must never start a live agent. The live runner lives in `tests/behavior/`, which `run.sh` does not glob.
- Success criteria (candidate arm): setup planning triggered >= 4/5; quick question triggered <= 1/5; non-coding triggered <= 1/5; read order graph-first >= 4/5. The baseline arm is reported beside it. A mismatch with the earlier subagent numbers is recorded as a finding, and the harness is not tuned to match.

---

## File Structure

| File | Responsibility |
|---|---|
| `tests/behavior/run-behavior` | Entry point: parse flags, preflight, print cost, confirm, loop over scenarios, arms and reps, write the record. |
| `tests/behavior/lib/secrets.sh` | Load the token from the Keychain, start a child with the token only in its environment, scan and scrub files for the token. |
| `tests/behavior/lib/arm.sh` | Turn a commit into a scratch plugin directory, install the logging shim, report the SHA. |
| `tests/behavior/lib/agent.sh` | Launch one isolated `claude -p` run and save its stream. |
| `tests/behavior/lib/grade.sh` | Per-scenario graders and the threshold summary. |
| `tests/behavior/lib/stream.py` | Read a `stream-json` file and print tool-call events as tab-separated lines. Used by `grade.sh` and the preflight probe. |
| `tests/behavior/lib/record.sh` | Write the run record (Markdown) with pins and per-rep evidence. |
| `tests/behavior/scenarios/<name>/prompt.txt` | The prompt the agent gets. |
| `tests/behavior/scenarios/<name>/scenario.conf` | Fixture mode, grader, baseline ref, candidate ref, threshold. |
| `tests/behavior/fixtures/storefront/` | A synthetic 24-file TypeScript storefront, used as the scratch repo. |
| `tests/behavior/stubs/` | Fake `claude`, `graphify` and `security` for the offline test. |
| `tests/behavior/README.md` | How to create the token, what a run costs, how to read a record. |
| `tests/behavior_harness.sh` | Offline test entry, picked up by `tests/run.sh`. It runs `tests/behavior/tests/<section>.sh`. |
| `tests/behavior/tests/<section>.sh` | One offline test file per task: `secrets`, `arm`, `grade`, `agent`, `runner`. |
| `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/` | Committed run records. |

## Tasks

### Task 1: Write the fixture repo and the four scenario definitions

**Files:**
- Create: `tests/behavior/fixtures/storefront/` (24 source files plus `README.md`)
- Create: `tests/behavior/scenarios/{setup-planning,setup-quick-question,setup-non-coding,read-order}/{prompt.txt,scenario.conf}`

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces: `scenario.conf` is a shell-sourceable file with exactly these keys:
  `FIXTURE_MODE` (`no-graph` or `graph`), `GRADER` (`setup-trigger` or `graph-first`),
  `BASELINE_REF`, `CANDIDATE_REF`, `PASS_RULE` (`at-least` or `at-most`), `PASS_COUNT` (integer),
  `SANDBOX` (`on` or `off`; all four start at `on`).

**Brief:** Write a small storefront in TypeScript and React Router style. It needs at least 20 files that `git ls-files` counts as source, so `graphify-setup status` does not print `small`. Name them so the planning prompt applies: `app/components/ProductItem.tsx`, `app/routes/products.$handle.tsx`, `app/lib/session.ts`, `app/lib/fragments.ts`, and at least 20 more. Each file holds real but short code, with imports between files so Graphify finds edges. It holds no secrets, no absolute paths and no copied third-party code.

Write the four scenarios:
- `setup-planning`: `no-graph`, `setup-trigger`, `c91be4c`, `5a972be`, `at-least`, `4`. The prompt asks the agent to use the writing-plans skill for the file-mapping part of this intent: "Add a 'recently viewed products' strip below the product details on the product page. Store the last 6 viewed product handles in a cookie." It forbids writing `plan.md` and editing source files. It tells the agent that it cannot reach its human partner, and that it should write any question it would ask under "Questions for my human partner", assume the answer is "no", and act on that answer.
- `setup-quick-question`: `no-graph`, `setup-trigger`, `c91be4c`, `5a972be`, `at-most`, `1`. Prompt: "Quick question: which file defines the ProductItem component, and what props does it take?", plus the same "cannot reach" paragraph.
- `setup-non-coding`: `no-graph`, `setup-trigger`, `c91be4c`, `5a972be`, `at-most`, `1`. Prompt: "Can you draft a two-sentence, friendly reminder I can send a teammate whose code review for me is a few days overdue?", plus the same paragraph.
- `read-order`: `graph`, `graph-first`, `8199034`, `c91be4c`, `at-least`, `4`. Same prompt as `setup-planning`.

The check is the existing helper. Extract it without a checkout: `git show 5a972be:plugins/superpowers/skills/using-superpowers/scripts/graphify-setup > "$TMPDIR/gs" && chmod +x "$TMPDIR/gs"`. Then a copy of the fixture made into a git repo prints `ask` from `"$TMPDIR/gs" status`. `tests/no_machine_content.sh` also passes.

**Steps:**
- [ ] Write the fixture files.
- [ ] Copy the fixture to a temp dir, `git init`, commit, and run `graphify-setup status` from the PR #2 branch; see `ask`.
- [ ] Run `graphify update .` in that copy; see a graph with more than 20 nodes and at least one `imports` edge.
- [ ] Write the four scenario directories.
- [ ] Run `bash tests/no_machine_content.sh`; see it pass.

### Task 2: Keep the token in the Keychain and out of every scratch file

**Files:**
- Create: `tests/behavior/lib/secrets.sh`
- Create: `tests/behavior/stubs/security`
- Create: `tests/behavior_harness.sh` (runs `tests/behavior/tests/<section>.sh`, all sections or the one named)
- Test: `tests/behavior/tests/secrets.sh`

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces, all in `secrets.sh`:
  - `wb_token_load` sets the shell variable `WB_TOKEN` (not exported) from `security find-generic-password -a "$USER" -s warden-behavior-oauth -w`. It returns 1 with a message naming the service when the item is missing.
  - `wb_child_exec <cmd> [args...]` runs the command in a subshell that first unsets every exported variable, then exports only `PATH`, `HOME`, `CLAUDE_CONFIG_DIR`, `XDG_CACHE_HOME`, `TMPDIR`, `LANG`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and `CLAUDE_CODE_OAUTH_TOKEN="$WB_TOKEN"`, then `exec`s the command. The caller sets `WB_CHILD_PATH`, `WB_CHILD_HOME`, `WB_CHILD_CONFIG`, `WB_CHILD_CACHE` and `WB_CHILD_TMP`.
  - `wb_leak_scan <dir>...` prints the paths of files that contain the token and returns 0 when there are none and 1 otherwise. It passes the token to `grep -F -f` through a process substitution, never in argv.
  - `wb_leak_scrub <file>...` replaces every occurrence of the token with `[REDACTED-TOKEN]` in place. It reads the token from an environment variable visible only to that one `python3 -I` process.
  - `wb_env_guard` returns 1 with a message naming the variable when `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set and non-empty, and 0 otherwise.
  - `wb_revoke_message` prints the three revoke steps from Global Constraints.

**Brief:** This task carries the main safety requirement. Tests, using a fake `security` stub that prints a fake token `sk-ant-oat01-FAKE…`:
1. `wb_token_load` sets `WB_TOKEN` and does not export it: `env` in the parent does not contain it.
2. With the item missing (the stub exits 44), `wb_token_load` returns 1 and names `warden-behavior-oauth`.
3. `wb_child_exec env` prints `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and the five path variables, and nothing else from the parent. For example, a parent `AWS_SECRET_ACCESS_KEY` does not appear.
4. The token never appears in any process's argv: a stub child that writes `ps -o args= -p $PPID` and its own argv to a file produces no token in that file.
5. `wb_leak_scan` finds a planted token in a nested file and returns 1. It returns 0 on a clean tree, and the token is absent from its own output.
6. `wb_leak_scrub` removes the token and keeps the rest of the file byte for byte.
7. `wb_env_guard` returns 1 when `ANTHROPIC_API_KEY=x` is set, returns 1 for `ANTHROPIC_AUTH_TOKEN=x`, and returns 0 when both are unset.
8. With `ANTHROPIC_API_KEY=x` exported in the parent, `wb_child_exec env` shows neither `ANTHROPIC_API_KEY` nor `ANTHROPIC_AUTH_TOKEN`.

Test command: `bash tests/behavior_harness.sh secrets`.

**Steps:**
- [ ] Write the eight tests; run them and see them fail with "secrets.sh not found".
- [ ] Write `secrets.sh` and the `security` stub.
- [ ] Run the tests and see them pass.

### Task 3: Turn a commit into a scratch plugin with a logging shim

**Files:**
- Create: `tests/behavior/lib/arm.sh`
- Test: `tests/behavior/tests/arm.sh`

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces: `wb_arm_materialize <repo> <ref> <dest> <shim-log>`. It writes the plugin to `<dest>/superpowers`, prints the full commit SHA, and returns 1 when the ref does not exist.
  - It extracts `plugins/superpowers` from `<ref>` with `git -C <repo> archive <ref> plugins/superpowers`, never by a checkout.
  - When `skills/using-superpowers/scripts/graphify-setup` exists, it renames it to `graphify-setup.real` and writes a wrapper at the old path. The wrapper appends `<basename of PWD>\t<args>` to `<shim-log>` and `exec`s the real script.
  - When that script does not exist, it installs no shim.

**Brief:** Tests use a temp git repo with two commits, one with the script and one without:
1. Materializing the commit with the script gives a working wrapper: running `status` writes one log line and prints the real script's output.
2. Materializing the commit without the script installs no shim and writes no `.real` file.
3. The printed SHA equals `git rev-parse <ref>^{commit}`.
4. An unknown ref returns 1 and creates nothing in `<dest>`.
5. Warden's own `HEAD`, branch and status are unchanged after a run.

Test command: `bash tests/behavior_harness.sh arm`.

**Steps:**
- [ ] Write the five tests; run them and see them fail.
- [ ] Write `arm.sh`.
- [ ] Run the tests and see them pass.

### Task 4: Grade runs from tool calls, the shim log and git config

**Files:**
- Create: `tests/behavior/lib/grade.sh`, `tests/behavior/lib/stream.py`
- Test: `tests/behavior/tests/grade.sh`, with synthetic stream files under `tests/behavior/stubs/streams/`

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces:
  - `python3 -I stream.py <file>` prints one line per tool call: `<index>\t<tool name>\t<command or path>`. It reads `type: "assistant"` messages and their `tool_use` content blocks. It prints the model ID from the `system`/`init` event on a first line `model\t<id>`.
  - `wb_grade_setup_trigger <shim-log> <repo-name> <repo-dir>` prints `triggered=<0|1> declined=<0|1> setup_ran=<0|1> config=<value or unset>`.
  - `wb_grade_graph_first <stream-file>` prints `graph_first=<0|1> first=<tool>:<detail>`.
    - An exploration call is a `Read`, `Grep` or `Glob` call, or a `Bash` call whose command starts a `grep`, `rg`, `find`, `cat`, `sed`, `head` or `ls` on a fixture path.
    - A graph call is a `Bash` call whose command contains `graphify query`, `graphify explain` or `graphify path`.
    - `graph_first=1` when a graph call comes before the first exploration call.
  - `wb_threshold <count> <reps> <rule> <n>` prints `PASS` or `FAIL`.

**Brief:** Tests:
1. A shim log with `repo-A status` and `repo-A decline`, plus config `declined`, grades `triggered=1 declined=1`.
2. A log with only another repo's lines grades `triggered=0` for this repo.
3. Graph-first, read-first and no-exploration streams grade 1, 0 and 0.
4. A `Bash` call `cat graphify-out/GRAPH_REPORT.md` is not counted as exploration of source.
5. `stream.py` reads the model ID from the init event and ignores non-JSON lines without crashing.
6. `wb_threshold 4 5 at-least 4` gives PASS, `3 5 at-least 4` gives FAIL, and `2 5 at-most 1` gives FAIL.

Task 7 replaces the synthetic stream with a scrubbed real one, if the field names differ.

Test command: `bash tests/behavior_harness.sh grade`.

**Steps:**
- [ ] Write the synthetic streams and the six tests; see them fail.
- [ ] Write `stream.py` and `grade.sh`.
- [ ] Run the tests and see them pass.

### Task 5: Launch one isolated claude -p agent

**Files:**
- Create: `tests/behavior/lib/agent.sh`
- Create: `tests/behavior/stubs/claude` (separate from `tests/stubs/claude`)
- Test: `tests/behavior/tests/agent.sh`

**Depends on:** Task 2

**Model:** sonnet

**Interfaces:**
- Consumes: `wb_child_exec`, `WB_TOKEN`, and the `WB_CHILD_*` variables from `secrets.sh`.
- Produces: `wb_agent_run <run-dir> <repo-dir> <plugin-dir> <prompt-file> <model or ""> <on|off>`. The last argument is the scenario's `SANDBOX` value. It writes `<run-dir>/stream.jsonl` and `<run-dir>/stderr.txt` and returns the claude exit code.
  - It creates `<run-dir>/agent-home`, `<run-dir>/agent-home/.claude/settings.json`, `<run-dir>/cache` and `<run-dir>/tmp`.
  - The settings file allows `Bash`, `Read`, `Grep`, `Glob` and `Skill`. It denies `Write`, `Edit`, `NotebookEdit`, `WebFetch`, `WebSearch`, `Bash(security:*)` and `Bash(curl:*)`. These deny rules catch accidental access only.
  - With `on`, the settings file also holds the sandbox block from Global Constraints. The real home directory is the parent's `HOME`, captured before the scratch `HOME` replaces it. The Graphify read paths come from resolving `command -v graphify` and its `#!` interpreter.
  - It runs `claude -p --output-format stream-json --verbose --no-session-persistence --strict-mcp-config --plugin-dir <plugin-dir>`, plus `--model <id>` only when one is given. The prompt is read from the file into stdin. The working directory is `<repo-dir>`.
  - `PATH` holds the system directories, the directory of the real `graphify`, and the `claude` directory.

**Brief:** Tests with a stub `claude` that records its argv, cwd and env to a file:
1. The argv has `-p`, `--output-format stream-json`, `--no-session-persistence` and `--plugin-dir`, has no `--model` by default, and has `--model sonnet` when given.
2. The env has the scratch `HOME` and `CLAUDE_CONFIG_DIR` under `<run-dir>`, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`.
3. No argv element contains the token.
4. The settings file denies `Bash(security:*)`.
5. The working directory is the repo dir.
6. After the run, `wb_leak_scan <run-dir>` returns 0 for a stub that does not echo the token.
7. With `on`, the settings file holds `sandbox.enabled: true`, `allowUnsandboxedCommands: false`, `failIfUnavailable: true`, a `credentials.envVars` deny for each of the three variables, and a `denyRead` entry equal to the real home path. With `off`, it holds no `sandbox` key.

Test command: `bash tests/behavior_harness.sh agent`.

**Steps:**
- [ ] Write the stub and the seven tests; see them fail.
- [ ] Write `agent.sh`.
- [ ] Run the tests and see them pass.

### Task 6: Wire the runner: preflight, cost, loop and record

**Files:**
- Create: `tests/behavior/run-behavior`, `tests/behavior/lib/record.sh`, `tests/behavior/README.md`, `tests/behavior/stubs/graphify`
- Modify: `tests/behavior/stubs/claude` (add canned streams per scenario, and a shim call for planning prompts)
- Test: `tests/behavior/tests/runner.sh`

**Depends on:** Tasks 1, 2, 3, 4, 5

**Model:** sonnet

**Interfaces:**
- Consumes: every function above, plus `scenario.conf`.
- Produces: `run-behavior [--scenario <name>|all] [--reps N] [--model ID] [--fixture DIR] [--yes]`. Exit codes: 0 all criteria met; 1 a criterion failed; 2 usage error; 3 preflight failed (no agent started); 4 token found in output.

**Brief:**
- **Preflight runs before any agent**, in this order:
  1. `graphify --version` works.
  2. `claude --version` works.
  3. `wb_env_guard` passes, so neither `ANTHROPIC_API_KEY` nor `ANTHROPIC_AUTH_TOKEN` is set.
  4. `wb_token_load` succeeds.
  5. Both refs of every selected scenario resolve, after `git fetch fork` if needed.
- **The cost line** prints the agent count: 1 probe plus scenarios × 2 arms × reps. It also prints the model, either "account default" or the ID, and a token range of 40,000–60,000 per agent, taken from the subagent runs of 2026-10-20. Then it asks `Start N agents? [y/N]`.
- **The probe** runs once per sandbox mode used in the run, before the scenarios. It is one agent with the prompt "Run exactly this command and report its output: printenv CLAUDE_CODE_OAUTH_TOKEN | wc -c". The probe passes only when `stream.py` shows that Bash call, its tool result is `0`, and `wb_leak_scan` is clean. A failed probe exits 3 and starts nothing else.
- **For each rep:**
  1. Copy the fixture to a fresh repo named `<scenario>-<arm>-<rep>`, `git init` it and commit.
  2. For `graph` mode, run `graphify update .`.
  3. Materialize the arm with `wb_arm_materialize`.
  4. Run `wb_agent_run`.
  5. Run `wb_leak_scan` on the run dir. On a hit, run `wb_leak_scrub`, mark the run, print `wb_revoke_message`, and exit 4 at the end.
  6. Grade the rep.
- **`record.sh`** writes `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<UTC date>-<short id>.md`. It holds:
  - the pins, and the sandbox mode of each scenario with the reason when it is `off`
  - a table per scenario: arm, triggered or graph-first count, and the PASS/FAIL of the candidate criterion
  - the per-rep grade lines
  - the raw-output path written as `~/.cache/...`
- **The README** says to create the token in a separate terminal, never inside a Claude Code session, and without putting it in shell history: run `claude setup-token`, then `security add-generic-password -a "$USER" -s warden-behavior-oauth -w` and paste at the prompt. It also covers the cost, the exit codes, the revoke steps, and which guarantees are real (the probe and the leak scan) and which only catch accidents (deny rules, sandbox).

**Offline end-to-end tests** use stub `claude`, `graphify` and `security`. The stub `claude` emits canned streams by scenario, and it calls the shim when the prompt is a planning prompt:
1. Without `graphify` on `PATH`: exit 3, and the stub `claude` log is empty.
2. Answering `n` at the prompt: exit 0 or 2, and the stub `claude` log is empty.
3. A probe stream showing a non-zero `wc -c`: exit 3, and no scenario agent ran.
4. A full run with `--yes --reps 2`: exit 0, and the record file exists with all five pins.
5. A stub that echoes the token into its stream: exit 4, `wb_leak_scan` is clean afterwards, the record says "token found and removed" without the value, and the output contains the revoke steps.
8. With `ANTHROPIC_API_KEY=x` set: exit 3 before the cost prompt, and the stub `claude` log is empty.
6. The record passes `tests/no_machine_content.sh`.
7. Warden's own git status is unchanged after the run.

Test command: `bash tests/behavior_harness.sh runner`, then `bash tests/run.sh`.

**Steps:**
- [ ] Write the eight tests; see them fail.
- [ ] Write `run-behavior`, `record.sh` and the `graphify` stub.
- [ ] Run the tests and see them pass.
- [ ] Write the README.
- [ ] Run `bash tests/run.sh`, and confirm it starts no real `claude`.

### Task 7: Run the real probe and fix the stream format against it

**Files:**
- Modify: `tests/behavior/stubs/streams/` (add a scrubbed real stream), and `tests/behavior/lib/stream.py` only if the field names differ.

**Depends on:** Task 6. Also needs Nicolai's token in the Keychain.

**Model:** session

**Brief:**
1. Run `tests/behavior/run-behavior --scenario setup-quick-question --reps 1 --model sonnet`. This starts the probe plus 2 agents.
2. Check the probe:
   - The agent's shell sees `0` bytes of the token.
   - `wb_leak_scan` is clean.
   - The init event names the model.
   - The plugin loaded: the stream shows the Superpowers SessionStart context or a `Skill` tool.
3. If the probe fails, stop and report. Do not weaken the probe.
4. Check the sandbox against the grading. Run `setup-planning` and `read-order` for one rep each with `SANDBOX=on`, then check three things:
   - **Shim log:** it gets its lines.
   - **`decline`:** it writes `superpowers.graphify` to the repo's local git config. The docs predict it cannot, because `.git/config` in the working directory is write-protected.
   - **Graphify:** `graphify query` runs.
   For each scenario whose grading breaks, set `SANDBOX=off` in its `scenario.conf`. Record the reason, and put the risk 2 statement in its record. Keep `on` wherever grading works.
5. Save one scrubbed real stream as a grader fixture, and rerun `bash tests/behavior_harness.sh grade`.

**Steps:**
- [ ] Ask Nicolai to confirm the token is stored.
- [ ] Run the one-rep command above, and show the probe result.
- [ ] Run the sandbox check, and set each scenario's `SANDBOX` value from the result.
- [ ] Add the scrubbed stream fixture, and adjust `stream.py` if needed, test first.
- [ ] Run `bash tests/run.sh`, and see it pass.

### Task 8: Record the baseline and link it from PRs #1 and #2

**Files:**
- Create: `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<run>.md` (written by the runner)

**Depends on:** Task 7

**Model:** session

**Brief:**
1. Nicolai starts `tests/behavior/run-behavior --scenario all` after reading the cost line: 1 probe plus 4 scenarios × 2 arms × 5 reps, 41 agents.
2. Commit the record.
3. Compare the numbers with the 2026-10-20 subagent results, and write any difference as a finding in the record. Do not change graders or prompts to close a gap.
4. With Nicolai's go-ahead, comment the record link on PRs #1 and #2 in `NicoSik/Warden_public`.

**Steps:**
- [ ] Print the cost line, and wait for Nicolai to start the run.
- [ ] Commit the record.
- [ ] Write the findings section.
- [ ] Post the PR comments after Nicolai says yes.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2, 3, 4 | Each owns different files, including its own `tests/behavior/tests/<section>.sh`. Only Task 2 owns `tests/behavior_harness.sh`. |
| 2 | 5 | It uses `secrets.sh` from Task 2. |
| 3 | 6 | It wires Tasks 1–5 together. |
| 4 | 7 | It needs the whole runner and the real token. |
| 5 | 8 | It needs the verified probe and grader. |

After the last wave: the final review, the fix wave and the scoped re-review. There is no spec, so no `reconciling-specs`.

## Risks, worst first

1. **Token exposure (Tasks 2, 5, 7).** The token is a one-year credential for your subscription.
   - The real guarantees are the probe and the leak scan. If the env scrub does not cover `CLAUDE_CODE_OAUTH_TOKEN`, the probe stops the run before any scenario. If the token still appears in any output, the leak scan removes it, fails the run, and prints the revoke steps.
   - The `Bash(security:*)` deny rule and the sandbox's `denyRead` and `credentials` entries only catch accidental access. A determined agent could still reach the Keychain or the token another way.
2. **The agent leaving the scratch area (Task 5).** Where `SANDBOX=on`, the sandbox blocks reads of the real home and writes outside the run directory for Bash commands. The Read, Grep and Glob tools follow permission rules, not the sandbox. Where `SANDBOX=off` (the fallback):
   - Write tools are denied, and `HOME` and `CLAUDE_CONFIG_DIR` are scratch.
   - Bash still runs as your user, without a sandbox, so an absolute path can reach your real files.
   - The fixture prompts give the agent no reason to touch other paths.
3. **Wrong stream-format assumptions (Tasks 4, 7).** If the `stream-json` field names differ, the read-order grader is wrong. Task 7 checks it against a real stream before the baseline run.
4. **Different numbers from the subagent runs (Task 8).** `claude -p` loads skills through the plugin hook, not through a file the prompt names, and the fixture is synthetic, not Trendy. A difference is a finding, not a bug.
5. **Cost (Task 8).** 41 agents at 40,000–60,000 tokens is about 1.6–2.5 million tokens on the account default model. The cost line shows this, and `--model sonnet` lowers it.
6. **Synthetic fixture realism (Task 1).** A small fixture may make graph queries less useful than in a real repo. `--fixture` allows a local repo without committing it.

**Found, out of scope:** the Bash sandbox write-protects `.git/config` and `.git/hooks` in the working directory. In a real sandboxed session, `graphify-setup decline` and `setup` from PR #2 would fail. That needs its own fix in `graphify-setup`, outside this change.

**Ruled out:**
- quorum: deferred by decision Q3.
- `--bare`: it reads only an API key, never OAuth.
- Real `HOME`: it would touch `~/.claude`.
- Agent-tool subagents: the `SUBAGENT-STOP` confound.
- A planted-regression check: the baseline arm is the negative control.

**The riskiest task** is Task 2, because every later guarantee about the token rests on it.
