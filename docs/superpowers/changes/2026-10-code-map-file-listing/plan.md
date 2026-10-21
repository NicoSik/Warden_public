# Code Map File Listing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Code Map rule counts file listing as exploration, the grader scores the rule as written, and the behavior harness can measure the change per change folder.

**Architecture:** The grader `tests/behavior/lib/graph_first.py` decides, per trace, whether a graph query came before the first exploration call. The wrapper `tests/behavior/run-behavior` runs `claude plugin eval` per arm, and `tests/behavior/lib/record.py` grades the runs and writes the record. The rule text lives in two identical copies in the vendored Superpowers plugin.

**Tech Stack:** Bash, Python 3 (stdlib only, run with `python3 -I`), offline stub `claude` and `graphify`.

**Spec:** `docs/superpowers/changes/2026-10-code-map-file-listing/intent.md` (bounded change, no spec). The approved design is D1–D5 in `handoff.md`, with Nicolai's changes to D1 and D4 written into Tasks 1 and 4 below.

## Global Constraints

- The two copies of the Code Map rule stay identical.
- The grader is committed before the first gate run. After that commit, nobody edits `tests/behavior/lib/graph_first.py` or its traces.
- The held-out prompt is committed before the first run. After that commit, nobody edits it.
- Run records keep no machine paths and no transcript text.
- The existing `tests/behavior/evals/arms.conf` and its records stay as they are.
- The pre-commit scrub refuses any literal `/home/<name>` or `/Users/<name>` text, test files included. Build such paths from `$HOME`.
- Push and open PRs only on `NicoSik/Warden_public` (remote `fork`).
- Test command for the harness: `bash tests/behavior_harness.sh` (all) or `bash tests/behavior_harness.sh graph_first` / `runner` (one file).

## Risks (worst first)

1. **R1 — The grader misgrades a form after it is frozen.** Cost: the gate result is wrong, and the intent forbids a grader edit between gate runs. Task 1 carries this risk, so Task 1 gets one trace per allowed form and one trace per forbidden form in the intent.
2. **R2 — A baseline of `-` breaks the default two-arm path.** Cost: the existing baseline record and its tests break. The existing runner tests 1–8 stay unchanged and must still pass.
3. **R3 — The diagnostic print leaks transcript text into the record.** Cost: a public record holds transcript text. Runner test 6 already asserts that the record holds no `graphify query x` and no `a.ts`. Task 3 adds a test that the terminal does show that text, so the test proves the split.
4. **R4 — The held-out case is graded by the wrong grader.** `record.py` grades by `case == "read-order"` today, so `read-order-heldout` would fall through to the `triggered` grader and error. Task 3 makes every case whose name starts with `read-order` use `graph_first`.
5. **R5 — The wording is narrower than the grader.** The D4 text allows only an existence check of `graphify-out/`. The grader allows any command that touches only `graphify-out/`. An agent that follows the wording always passes the grader. The reverse gap is intended.

Ruled out:
- Changing the output of `graph_first.py` for the diagnostic print. It would touch the frozen grader. `record.py` loads `tool_calls` from it with `importlib` instead.
- An automatic check that the baseline stays below 4/5. The intent makes that a manual stop rule. The record already shows the baseline count as "report only".
- Parsing commands with `shlex`. The current grader splits on whitespace. Quoted paths with spaces do not occur in the fixture.

---

### Task 1: Grade file listing and graph-output checks as the intent states (D1)

**Files:**
- Modify: `tests/behavior/lib/graph_first.py:7-50`
- Create: `tests/behavior/tests/traces/16_*.jsonl` to `tests/behavior/tests/traces/3N_*.jsonl` (one file per case below)
- Modify: `tests/behavior/tests/graph_first.sh`

**Depends on:** none

**Model:** `sonnet` — one production file, with every behavior and test stated below.

**Brief:** The grader must count every listing, search or read as exploration, except a small set of checks on `graphify-out/`. Today it treats `ls graphify-out` (no slash) and `cd graphify-out && cat GRAPH_REPORT.md` as exploration. It also ignores `tree` and `wc`. A probe of the current code gives these results:

| command | current | wanted |
|---|---|---|
| `ls graphify-out/` | not exploration | not exploration |
| `cat graphify-out/GRAPH_REPORT.md` | not exploration | not exploration |
| `ls graphify-out` | exploration | not exploration |
| `ls -la graphify-out` | exploration | not exploration |
| `cd graphify-out && cat GRAPH_REPORT.md` | exploration | not exploration |
| `tree` | ignored | exploration |
| `wc -l app/x.ts` | ignored | exploration |

The rule to build in `bash_first`:

1. Add `tree` and `wc` to `EXPLORE_CMD`. Capture the verb.
2. A segment with an explore verb is a graph-output check when it has at least one path token and every path token in it names `graphify-out`. This holds for every explore verb, `grep`, `rg` and `find` included. A path token is a token that contains `/`, or that equals `graphify-out` or `./graphify-out`. A token names `graphify-out` when it equals `graphify-out`, `./graphify-out`, or starts with `graphify-out/` or `./graphify-out/`, and has no `..` part.
3. A segment with an explore verb and no path token is exploration (for example `ls`, `tree`, `cat README.md`). The current special case `not paths and OUT in seg` goes away, because rule 2 covers it.
4. `cd graphify-out`, `cd graphify-out/` and `cd ./graphify-out` set a flag for the rest of the command. While the flag is set, every argument that is not a flag (does not start with `-`) and has no `..` part counts as a `graphify-out` path, and a segment with no argument counts as a check of `graphify-out`. Any other `cd` clears the flag.
5. Nicolai ruled on 2026-10-21 that any command touching only `graphify-out/` is allowed, since D4 forbids only touching source files. A command that touches any other path, or no path, stays exploration.
6. `test` and `[` are not explore verbs. They stay ignored.
7. For the tools, use the same naming rule as rule 2. `Read` is not exploration when `file_path` names `graphify-out`. `Grep` is not exploration when `path` names `graphify-out`. `Glob` is not exploration when `path` names `graphify-out`, or when `path` is empty and `pattern` names `graphify-out`. A `Grep` or `Glob` call with no `path` searches the repository, so it is exploration (except the Glob pattern case).

Each new trace holds one Bash (or tool) call followed by `graphify query "x"`, in the format of `traces/8_gitlsfiles_then_graph.jsonl`. Want 1 (allowed check, then query):
- `ls graphify-out`, `ls graphify-out/`, `ls -la graphify-out`, `ls graphify-out/graph.json`
- `test -d graphify-out`, `test -f graphify-out/graph.json`, `[ -d graphify-out ]`, `[ -f graphify-out/graph.json ]`
- `cat graphify-out/GRAPH_REPORT.md`, `head -n 50 graphify-out/GRAPH_REPORT.md`, `tail graphify-out/GRAPH_REPORT.md`, `wc -l graphify-out/GRAPH_REPORT.md`, `tree graphify-out`
- `cd graphify-out && cat GRAPH_REPORT.md`
- `grep -n foo graphify-out/GRAPH_REPORT.md`, `rg foo graphify-out`, `find graphify-out -name '*.json'`
- the Grep tool with `pattern` `foo` and `path` `graphify-out`
- the Glob tool with `pattern` `graphify-out/*.json` and no `path`
- the Read tool on `graphify-out/GRAPH_REPORT.md` (trace 9 already covers this; do not duplicate it)

Want 0 (exploration first):
- `tree`, `wc -l app/x.ts`, `ls` (repo root), `ls -la`
- `cd graphify-out && cat ../app/x.ts`, `cat graphify-out/../app/x.ts`
- `grep -rn foo graphify-out app`, `find . graphify-out -name '*.ts'` (one path outside `graphify-out/` is enough)
- the Grep tool with `pattern` `foo` and `path` `app`
- the Glob tool with `pattern` `app/**/*.ts` and no `path`
- `cd graphify-out && cd .. && ls`

The existing traces 1–15 keep their current expected values.

**Steps:**
- [ ] Write the new traces and add one `expect` line per trace to `graph_first.sh`.
- [ ] Run `bash tests/behavior_harness.sh graph_first`. See the new rows for `ls graphify-out`, `ls -la graphify-out`, `cd graphify-out && cat GRAPH_REPORT.md`, `tree`, `wc -l app/x.ts`, `grep … graphify-out/…` and the Grep tool fail.
- [ ] Change `EXPLORE_CMD`, `bash_first` and `classify` as rules 1–7 state.
- [ ] Run `bash tests/behavior_harness.sh graph_first`. See every row pass, traces 1–15 included.
- [ ] Commit: `fix: grade file listing and graph-output checks as the Code Map intent states`. The grader is frozen from this commit.

### Task 2: Add the held-out read-order case (D2)

**Files:**
- Create: `tests/behavior/evals/read-order-heldout/` (`case.yaml`, `prompt.md`, `scaffold.sh`, `graders/bash-used.md`)

**Depends on:** none

**Model:** `sonnet` — a copy with two changed lines, and no behavior to test.

**Brief:** Copy `tests/behavior/evals/read-order/` to `tests/behavior/evals/read-order-heldout/`. Keep the executable bit on `scaffold.sh`. Change two things only:
- In `case.yaml`, set `name: read-order-heldout`.
- In `prompt.md`, keep the front matter. Replace the first body paragraph with: `Find where the product page reads the session cookie, and list the files a change to the cookie format would touch. Do not edit files.` Keep the "You cannot reach your human partner…" paragraph word for word.

Check: `diff -r tests/behavior/evals/read-order tests/behavior/evals/read-order-heldout` shows only the `name:` line and the first body paragraph.

**Steps:**
- [ ] Copy the directory with `cp -Rp`.
- [ ] Edit `case.yaml` and `prompt.md`.
- [ ] Run the `diff -r` check and see only the two changes.
- [ ] Commit: `test: add a held-out read-order case`. The prompt is frozen from this commit.

### Task 3: Per-change arms and record folder, candidate-only rows, and a first-commands print (D3)

**Files:**
- Modify: `tests/behavior/run-behavior`
- Modify: `tests/behavior/lib/record.py`
- Modify: `tests/behavior/stubs/claude`
- Modify: `tests/behavior/tests/runner.sh`
- Modify: `tests/behavior/README.md`

**Depends on:** none

**Model:** `sonnet` — crosses files.

**Brief:** The wrapper gets three abilities and one diagnostic.

1. `--arms FILE` sets the arms file. The default stays `$EVALS/arms.conf`. A missing file exits 2 with `arms file not found: FILE`. The ref error message says `ref X in <basename of FILE> does not resolve`.
2. `--record-dir DIR` sets the record folder. The precedence is: the flag, then `WARDEN_BEHAVIOR_RECORD_DIR`, then the current default folder.
3. A baseline of `-` in an arms row means "candidate only".
   - `run-behavior` does not resolve `-`. It passes `-` through to `$WORK/conf`. `REFS` leaves out `-`.
   - The agent count and the cost estimate count one arm for such a row, not two. For example one `read-order` row with baseline `-` and 5 runs prints `Start 5 agents? [y/N]`.
   - `record.py` grades only the candidate arm for such a row. The Results table has no baseline row for that case. The Pins list leaves out `-`.
4. Every case whose name starts with `read-order` is graded by `graph_first`. That covers `read-order-heldout`. The criterion label is `graph-first`. In `run-behavior`, the cost estimate treats these cases like `read-order`. In `stubs/claude`, these cases behave like `read-order` (a failing run reads `a.ts` first, and the grader list is `bash-used`).
5. After grading and before cleanup, `record.py` prints to stdout, for every run of a `read-order*` case, a header `first commands: <case> / <arm> / run <i>` and then the first 5 tool calls, one per line, as `  <Tool>: <input>`. The input is the Bash `command`, or else `file_path`, `path` or `pattern`. Collapse whitespace and cut each line at 160 characters. Load `tool_calls` from `graph_first.py` with `importlib.util.spec_from_file_location`, so the frozen grader stays untouched. This text goes to the terminal only. It never goes into the record file.

Update the usage line in the script header, in `usage()`, and in `README.md` to `run-behavior [--case <name>|all] [--runs N] [--model ID] [--arms FILE] [--record-dir DIR] [--yes]`. Document the three new behaviors in `README.md`.

New tests in `runner.sh`. Each writes its arms file under `$T`. Tests 1–8 stay unchanged and must still pass.
- **9 `--arms` and `--record-dir`:** an arms file with one row `read-order c91be4c 7d972fa at-least 4`, and `--record-dir "$T/other"`. Assert: 2 eval calls, a record in `$T/other`, and no record in `$T/runs`.
- **10 candidate only:** the row `read-order - 7d972fa at-least 4`, without `--yes`, with answer `n`. Assert that the prompt says `Start 5 agents? [y/N]`. Then the same with `--yes`. Assert: 1 eval call, the Results table has a `| read-order | candidate |` row and no `| read-order | baseline |` row, and no Pins line holds ` - (`.
- **11 held-out grading:** the row `read-order-heldout - 7d972fa at-least 4`, with `--yes` and `STUB_TRIG_1_READ_ORDER_HELDOUT=2`. Assert: exit 1, the table row shows `2/5`, `graph-first >= 4` and `FAIL`, and the run lines hold `graph_first=`.
- **12 first commands on the terminal only:** run 11's output holds `first commands: read-order-heldout / candidate / run 1` and `Bash: graphify query x`. The record holds neither `graphify query x` nor `a.ts`.
- **13 missing arms file:** `--arms "$T/nope.conf"` exits 2, prints `arms file not found`, and makes no eval call.

**Steps:**
- [ ] Write tests 9–13 in `runner.sh`.
- [ ] Run `bash tests/behavior_harness.sh runner` and see 9–13 fail and 1–8 pass.
- [ ] Change `stubs/claude` for the `read-order*` cases.
- [ ] Add `--arms` and `--record-dir` to `run-behavior`.
- [ ] Handle the `-` baseline in `run-behavior` (conf, refs, agent count, cost).
- [ ] Handle the `-` baseline and the `read-order*` cases in `record.py`.
- [ ] Add the first-commands print to `record.py`.
- [ ] Run `bash tests/behavior_harness.sh` and see every test pass.
- [ ] Update `README.md`.
- [ ] Commit: `feat: per-change arms and record folder, candidate-only rows, first-commands print`.

### Task 4: Name file listing in the Code Map rule (D4)

**Files:**
- Modify: `plugins/superpowers/skills/using-superpowers/SKILL.md:38`
- Modify: `plugins/superpowers/skills/subagent-driven-development/implementer-prompt.md:79`

**Depends on:** none

**Model:** `sonnet` — a two-line text change.

**Brief:** Replace step 1 in both files with this text. Keep each file's indentation and the `1. ` prefix:

```
1. Run `graphify query "<question>"` before you list, search or read any source file (for example `git ls-files`, `find`, `tree`, `grep` or `cat`). You may first check that `graphify-out/` exists.
```

Check: `git grep -n 'before you list, search or read any source file' plugins/` prints exactly two lines. After you strip the leading whitespace, the two lines are identical. `git grep -n 'before the first grep, find' plugins/` prints nothing.

**Steps:**
- [ ] Edit both files.
- [ ] Run both `git grep` checks and compare the two lines.
- [ ] Commit: `fix: count file listing as exploration in the Code Map rule`. Write down the commit SHA for Task 5.

### Task 5: Add the arms file for this change (D5)

**Files:**
- Create: `docs/superpowers/changes/2026-10-code-map-file-listing/arms.conf`

**Depends on:** Task 4

**Model:** session

**Brief:** Write two rows. `<T4>` is the full SHA of the Task 4 commit:

```
read-order 7d972fa <T4> at-least 4
read-order-heldout - <T4> at-least 4
```

Check: `git rev-parse --verify 7d972fa^{commit}` and `git rev-parse --verify <T4>^{commit}` both succeed.

**Steps:**
- [ ] Write the file.
- [ ] Run the check.
- [ ] Commit: `chore: add the arms file for the Code Map file-listing change`.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2, 3, 4 | Each task owns different files. All four share one worktree, so the controller commits them in the order 1, 2, 3, 4. The grader commit comes first. |
| 2 | 5 | It needs the SHA of the Task 4 commit. |

After the last wave: the final review, the fix wave and the scoped re-review. This is a bounded change, so there is no spec to reconcile.

## After the plan: the gate (from `handoff.md`)

1. Nicolai starts the gate run on Sonnet, because it asks for `y` and uses his plan:
   `tests/behavior/run-behavior --arms docs/superpowers/changes/2026-10-code-map-file-listing/arms.conf --record-dir docs/superpowers/changes/2026-10-code-map-file-listing/runs --case read-order --model sonnet`
2. Pass means the candidate scores at least 4/5 and the baseline scores below 4/5. If the baseline reaches 4/5, stop and report that the case cannot show the change.
3. If the candidate fails, revise the Task 4 wording from the printed first commands. Commit it, update `<T4>` in `arms.conf`, and rerun. Stop after 3 gate runs.
4. After the gate passes, run `--case read-order-heldout` once. Report the count. Do not gate on it.
5. Delete `handoff.md`. Push to `fork`, open the PR on `NicoSik/Warden_public`, and hand Nicolai the squash-merge command.
