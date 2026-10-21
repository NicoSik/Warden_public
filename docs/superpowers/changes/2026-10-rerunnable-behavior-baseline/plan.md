# Rerunnable Behavior Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tests/behavior/run-behavior` runs the Graphify trigger scenarios with `claude plugin eval` against a baseline and a candidate commit of the Superpowers plugin, and writes one run record that compares the arms.

**Architecture:** An eval suite (cases, graders, scaffold scripts, a shared fixture) lives in `tests/behavior/evals/`. The wrapper copies each arm's `plugins/superpowers` from git into a scratch folder, copies the suite in under `warden-evals/`, runs `claude plugin eval` once per arm, applies one extra trace check for read order, and writes a Markdown record.

**Tech Stack:** Bash (3.2-compatible), git, `claude plugin eval` (Claude Code 2.1.305), Graphify CLI 0.9.92 (fixture setup only), `python3 -I` for JSON.

**Spec:** `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/intent.md` (bounded change, no spec)

## Global Constraints

- No quorum. `claude plugin eval` plus a thin wrapper.
- A run never touches a real project, the real `~/.claude`, or Warden's own git state. Arms come from `git archive`, never a checkout.
- Missing `graphify` or `claude`: exit 3 before any agent starts.
- `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` set and non-empty: exit 3 before any agent starts, naming the variable.
- Every eval call passes `--no-publish --ablation none --scaffold --trust-plugin --keep-temp --eval-dir warden-evals --json <file>`, plus `--allow-tools Bash` and `--runs <N>` (default 5), and `--model <id>` only when given.
- The cost line before the run prints: agent count (cases × 2 arms × runs), the model ("account default" or the ID), and an estimate of US$0.10–0.40 per planning run and US$0.02–0.10 per other run, labelled exactly: `list-price estimate; not billed on a subscription login, uses your plan's usage limits`. It then asks `Start N agents? [y/N]`. `--yes` skips the prompt; only the offline test uses it.
- Every record pins: Claude Code version (`claudeVersion` from the result JSON), model, each arm's full commit SHA, `graphify --version`, and the fixture tree hash.
- The record states: "Runs measure attempts. Inside the eval sandbox on macOS, git, the home-installed Graphify binary, and `.git/config` writes are blocked, so `graphify-setup` and `graphify query` fail inside a run."
- Success criteria (candidate arm): setup planning triggered >= 4/5; quick question triggered <= 1/5; non-coding triggered <= 1/5; read order graph-first >= 4/5. The baseline arm is reported beside each. A gap with the 2026-10-20 subagent numbers is a finding, and nothing is tuned to close it.
- Committed records contain no absolute home path (`tests/no_machine_content.sh` stays green). Raw results stay in the scratch folder, outside the repo.
- `tests/run.sh` never starts a live agent. The live wrapper lives in `tests/behavior/`, which `run.sh` does not glob.

---

## Tasks

### Task 1: Write the eval suite: fixture, four cases, graders, scaffold scripts

**Files:**
- Create: `tests/behavior/evals/_fixture/storefront/` (24 source files + `README.md`)
- Create: `tests/behavior/evals/{setup-planning,setup-quick-question,setup-non-coding,read-order}/{prompt.md,case.yaml,scaffold.sh,graders/*.md}`
- Create: `tests/behavior/evals/arms.conf`

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces:
  - `arms.conf` lines are `<case-name> <baseline-ref> <candidate-ref> <at-least|at-most> <count>`. The four lines are exactly:
    - `setup-planning c91be4c 5a972be at-least 4`
    - `setup-quick-question c91be4c 5a972be at-most 1`
    - `setup-non-coding c91be4c 5a972be at-most 1`
    - `read-order 8199034 c91be4c at-least 4`
  - Each setup case has a grader named `triggered`. The read-order case has one `tool_used` grader named `bash-used` so the case loads; its real grading is wrapper-side.

**Brief:**
- **The fixture** is a small TypeScript storefront in React Router style. It has at least 20 files that `git ls-files` counts as source, including `app/components/ProductItem.tsx`, `app/routes/products.$handle.tsx`, `app/lib/session.ts` and `app/lib/fragments.ts`, with imports between files. It holds no secrets and no absolute paths.
- **Each `scaffold.sh`:**
  - copies `../_fixture/storefront/` into the empty workspace. The case dir path comes from `$(dirname "$0")`.
  - runs `git init -q -b main`, sets a local user, and commits.
  - For `read-order` only, it then runs `graphify update .`.
  - It exits non-zero on any failure.
- **`case.yaml`** sets `schema_version: "1.1"`, `name`, and `context.scaffold_script: scaffold.sh`.
- **`prompt.md` frontmatter:** `max_turns: 40`, `timeout_seconds: 900`, `allowed_tools: [Bash, Read, Grep, Glob, Skill]`.
- **Prompts:**
  - `setup-planning` and `read-order`: "Use the writing-plans skill for the file-mapping part of this approved intent: 'Add a recently viewed products strip below the product details on the product page. Store the last 6 viewed product handles in a cookie.' Do not write plan.md and do not edit source files."
  - `setup-quick-question`: "Quick question: which file defines the ProductItem component, and what props does it take?"
  - `setup-non-coding`: "Can you draft a two-sentence, friendly reminder I can send a teammate whose code review for me is a few days overdue?"
  - Every prompt ends with: "You cannot reach your human partner. If your instructions tell you to ask them something, write the exact question under 'Questions for my human partner', assume the answer is 'no', and act on that answer."
- **Graders:**
  - The setup cases have `graders/triggered.md` with `type: tool_used`, `tool: Bash`, and `input_match: "graphify-setup[^\"]*\\bstatus"`.
  - The planning case also has `min: 1`. The other two have `min: 0` and `max: 0`.
  - `read-order` has `graders/bash-used.md` (`tool_used`, `tool: Bash`, `min: 0`).

**Check:** use the existing helper, extracted without a checkout. Run `git show 5a972be:plugins/superpowers/skills/using-superpowers/scripts/graphify-setup > "$TMPDIR/gs"`, then `chmod +x "$TMPDIR/gs"`. In a copy of the fixture made into a git repo, `"$TMPDIR/gs" status` prints `ask`. `graphify update .` in that copy builds a graph with at least one `imports` edge. `bash tests/no_machine_content.sh` passes.

**Steps:**
- [ ] Write the fixture.
- [ ] Run the `ask` check and the graph check above.
- [ ] Write the four cases and `arms.conf`.
- [ ] Run `bash tests/no_machine_content.sh` and see it pass.

### Task 2: Write the graph-first trace check

**Files:**
- Create: `tests/behavior/lib/graph_first.py`
- Create: `tests/behavior/tests/graph_first.sh`, `tests/behavior/tests/traces/*.jsonl`
- Create: `tests/behavior_harness.sh` (runs every `tests/behavior/tests/*.sh`, or the one named as `$1`; exits non-zero on any failure)

**Depends on:** none

**Model:** sonnet

**Interfaces:**
- Produces: `python3 -I graph_first.py <trace.jsonl>` prints `graph_first=1` or `graph_first=0`, then `first=<tool>:<detail>`, and exits 0. It exits 2 on an unreadable file.
  - The trace format is the one plugin eval keeps: one JSON object per line. Tool calls are `message.content[]` blocks with `type: "tool_use"`, a `name`, and an `input` (a Bash `input.command`).
  - An **exploration call** is `Read`, `Grep` or `Glob`, or a `Bash` command that starts `grep`, `rg`, `find`, `cat`, `sed`, `head` or `ls` and does not name `graphify-out/`.
  - A **graph call** is a `Bash` command containing `graphify query`, `graphify explain` or `graphify path`.
  - `graph_first=1` when a graph call comes before the first exploration call.

**Brief:** Six synthetic traces, each a few JSON lines in the format above:
1. A graph query, then `Read` → 1.
2. `Read`, then a graph query → 0.
3. Only `Grep` → 0.
4. `cat graphify-out/GRAPH_REPORT.md`, then a graph query, then `Read` → 1, because reading the report is not exploration.
5. No tool calls → 0.
6. Non-JSON lines mixed in → no crash, same result as without them.

Test command: `bash tests/behavior_harness.sh graph_first`.

**Steps:**
- [ ] Write the traces and the six tests; see them fail.
- [ ] Write `graph_first.py`.
- [ ] Run the tests and see them pass, then run `bash tests/run.sh`.

### Task 3: Write the wrapper and the run record

**Files:**
- Create: `tests/behavior/run-behavior`, `tests/behavior/lib/record.py`, `tests/behavior/README.md`
- Create: `tests/behavior/tests/runner.sh`, `tests/behavior/stubs/{claude,graphify}`

**Depends on:** Tasks 1, 2

**Model:** sonnet

**Interfaces:**
- Consumes: `arms.conf` from Task 1. `graph_first.py` from Task 2.
- Produces:
  - `run-behavior [--case <name>|all] [--runs N] [--model ID] [--yes]`.
  - Exit codes: 0 all criteria met; 1 a criterion failed; 2 usage error or partial eval; 3 preflight failed.
  - Records are written to `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<UTC date>-<short id>.md`.

**Brief:**
- **Preflight,** in this order:
  1. `claude --version` works.
  2. `graphify --version` works.
  3. Neither `ANTHROPIC_API_KEY` nor `ANTHROPIC_AUTH_TOKEN` is set.
  4. Every ref in `arms.conf` resolves, after `git fetch fork` if needed.
- **Cost line** and confirm, exactly as in Global Constraints.
- **For each arm ref used,** once:
  1. Create a scratch dir with `mktemp -d`.
  2. Run `git archive <ref> plugins/superpowers | tar -x -C <scratch>`.
  3. Copy `tests/behavior/evals/` to `<scratch>/plugins/superpowers/warden-evals/`, dropping `arms.conf`.
  4. Run the eval command from Global Constraints with `--case` set to that arm's cases.
- **Per case and arm:** a run counts as triggered when its `triggered` grader passed, read from the result JSON at `cases[].arms.with[].graders[]`. For `read-order`, run `graph_first.py` on each run's `tracePath`.
- **The record** (`record.py`) holds:
  - the pins
  - the "Runs measure attempts" statement
  - one table: case, arm, SHA, count/runs, criterion, PASS/FAIL (candidate only)
  - per-run lines
  - the cost from `costUsd`, labelled "list-price estimate"
- **Afterwards,** delete the scratch dirs and every `tracePath` parent dir the result names.
- **The README** covers running it, the cost label, what "attempts" means, and the exit codes.

**Offline tests** use stub `claude` and `graphify` on `PATH`. The `claude` stub handles `--version`, and handles `plugin eval` by writing a canned result JSON and trace files. It records its argv.
1. No `graphify` on `PATH`: exit 3, no `plugin eval` call.
2. `ANTHROPIC_API_KEY=x`: exit 3, no `plugin eval` call, and the message names the variable.
3. Answer `n`: no `plugin eval` call.
4. The cost line contains the exact label text.
5. `--yes --runs 2`: one `plugin eval` call per arm, each with `--no-publish --ablation none --scaffold --keep-temp --eval-dir warden-evals --runs 2`, and none with `--model`.
6. The record exists, holds all five pins and the attempts statement, and passes `tests/no_machine_content.sh`.
7. Canned results where the candidate planning count is 3 of 5: exit 1, and the table shows FAIL.
8. Warden's `git status --porcelain` is unchanged, and no scratch dir is left.

Test command: `bash tests/behavior_harness.sh runner`, then `bash tests/run.sh`.

**Steps:**
- [ ] Write the stubs and the eight tests; see them fail.
- [ ] Write `run-behavior` and `record.py`.
- [ ] Run the tests and see them pass.
- [ ] Write the README; run `bash tests/run.sh` and confirm no real `claude` started.

### Task 4: Run one real case, check the result format, then record the baseline

**Files:**
- Create: `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<run>.md` (written by the wrapper)
- Modify: `tests/behavior/stubs/claude` and `tests/behavior/lib/*` only if the real format differs, test first.

**Depends on:** Task 3

**Model:** session

**Brief:**
1. Run `run-behavior --case setup-quick-question --runs 1 --model haiku`.
2. Confirm four things:
   - the real result JSON matches the paths the wrapper reads
   - the trace has the expected `tool_use` shape
   - the plugin's SessionStart context loaded (the trace shows the Superpowers skills)
   - the scratch dirs are gone
3. Fix any format gap, test first.
4. Nicolai reads the cost line and starts `run-behavior --case all`.
5. Commit the record. Write any gap with the 2026-10-20 numbers as a finding.
6. With Nicolai's go-ahead, comment the record link on PRs #1 and #2.

**Steps:**
- [ ] One-run format check; fix gaps test-first.
- [ ] Nicolai starts the full run.
- [ ] Commit the record with findings.
- [ ] Post PR comments after Nicolai says yes.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2 | They own different files. Only Task 2 owns `tests/behavior_harness.sh`. |
| 2 | 3 | It reads Task 1's `arms.conf` and runs Task 2's checker. |
| 3 | 4 | It needs the working wrapper and a real run. |

After the last wave: the final review, the fix wave and the scoped re-review. There is no spec, so no `reconciling-specs`.

## Risks, worst first

1. **Attempts, not outcomes (all tasks).** The sandbox blocks `git`, the Graphify binary and `.git/config` writes, so the runs show whether the agent tries the right step, not whether the step works. Every record states this.
2. **Result-format assumptions (Tasks 2, 3).** The JSON paths and trace shape come from four probe runs on 2026-10-21. Task 4 checks them on a real run before the baseline.
3. **Kept temp dirs (Task 3).** `--keep-temp` leaves transcripts in `/private/tmp/e-*`. The wrapper deletes them after grading. A crash leaves them behind, and the README says where they are.
4. **Different numbers from the subagent runs (Task 4).** The agent loads skills through the plugin hook in a fresh session, and the fixture is synthetic. A gap is a finding.
5. **Usage (Task 4).** About 40 agents on the account default model use a real share of the plan's limits. The cost line shows the list-price estimate first.

**Ruled out:**
- The custom `claude -p` runner, the token and Keychain handling, and the logging shim: plugin eval covers all three, and the agent's shell saw no login credential.
- Turning the sandbox off: plugin eval has no option for it.
- Installing Graphify outside the home folder: it changes the machine, git would still be blocked, and it was not chosen.

**The riskiest task** is Task 3, because every count in the record comes from its reading of the result JSON.
