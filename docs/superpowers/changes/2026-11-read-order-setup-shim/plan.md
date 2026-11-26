# Read-order setup shim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan wave by wave. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the `read-order` and `read-order-heldout` evals, `graphify-setup status` prints `ready`, as in a real session in a repository with a graph. Their score then measures graph-first reading again.

**Architecture:** `tests/behavior/run-behavior` builds one scratch plugin per arm commit and runs every case of that commit on it. This change affects only the two read-order cases in an arm that has `scripts/graphify-setup`. For each such case, the wrapper makes a separate copy of the arm, puts a stub in place of that script, and runs the eval on the copy. `lib/record.py` pins the setup status of each read-order case per arm.

**Tech Stack:** bash 3.2, Python 3 standard library (`python3 -I`), git, the existing offline stubs in `tests/behavior/stubs/`.

**Spec:** none. This is a bounded change. The plan argues from `docs/superpowers/changes/2026-11-read-order-setup-shim/intent.md` (commit `9eb108f`).

## Global Constraints

- Stubbed cases: exactly `read-order` and `read-order-heldout`. Every other case runs on the unchanged arm.
- Each stubbed case runs on its own copy of the arm. The wrapper never replaces the script in place and never restores it.
- The stub prints `ready` and exits 0 for `status` only. Any other subcommand, or no subcommand, exits non-zero and prints `stub: only status is supported` on stderr.
- An arm without `scripts/graphify-setup` gets no stub. Its record pin says `not present`.
- An arm with a stub gets the record pin `stubbed (ready)`.
- Setup cases get the real script byte for byte, also after a stubbed case in the same arm.
- No file under `plugins/` changes.
- Nobody regrades a record. Old records only get a note.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `tests/behavior/lib/setup-status-stub` (new, mode 755) | The stub script | 1 |
| `tests/behavior/run-behavior` | Per-case arm copy with the stub, pin arguments to `record.py` | 1 |
| `tests/behavior/lib/record.py` | `--setup-status` pins | 1 |
| `tests/behavior/tests/runner.sh` | Offline test 17 | 1 |
| `tests/behavior/README.md` | Describe the shim and its pin | 2 |
| Five run records | A note on the unreliable `read-order` rows | 2 |

### Task 1: Stub the setup status in the read-order cases

**Files:**
- Create: `tests/behavior/lib/setup-status-stub`
- Change: `tests/behavior/run-behavior` (the per-case loop at lines 159-170 and the `record.py` call at lines 201-204)
- Change: `tests/behavior/lib/record.py` (argument parsing near line 155, the Pins block near lines 255-270)
- Test: `tests/behavior/tests/runner.sh` (new section 17, after section 16)

**Depends on:** none

**Model:** standard tier. The task crosses the wrapper, the record writer, a new stub and the offline test.

This task resists decomposition. The pin arguments come from the same loop that makes the copies, and one offline test proves both.

**Interfaces:**
- Produces: the stub at `tests/behavior/lib/setup-status-stub`.
- Produces: `record.py --setup-status SHA:CASE=VALUE`, repeatable. VALUE is `stubbed (ready)` or `not present`. Each one prints a pin line `- Setup status of <SHA> in <CASE>: <VALUE>` in the Pins block, after the Arm commit lines, in the order given.

**Brief:**

The stub is a bash script. With exactly one argument `status`, it prints `ready` and exits 0. Otherwise it prints `stub: only status is supported` on stderr and exits 2. Its header comment says that it is an eval stub for the read-order cases and points to `tests/behavior/README.md`.

In `run-behavior`, keep the list `SETUP_STUB_CASES="read-order read-order-heldout"` beside the other constants. Inside the per-case loop:
- If the case is in that list and `$scratch/plugins/superpowers/scripts/graphify-setup` exists, copy the whole `$scratch` to `$WORK/arm-$n-$c` with `cp -R`. Copy the stub over `scripts/graphify-setup` in the copy, keep mode 755, and run the eval with `cd` into the copy and the copy's plugin path. Add `--setup-status "$sha:$c=stubbed (ready)"` to the `record.py` arguments.
- If the case is in that list and the arm has no `graphify-setup`, run on `$scratch` as today, and add `--setup-status "$sha:$c=not present"`.
- For every other case, run on `$scratch` as today, and add no pin.

The trace copy step reads `tracePath` from the result, so it needs no change. The scratch arm itself is never changed by this step.

In `record.py`, add the repeatable `--setup-status` argument. Split each value on the first `=`, and the left part on the first `:`. Print the pin lines as stated under Interfaces. A run with no `--setup-status` prints no such line, so every existing record format stays the same.

Section 17 of `tests/behavior/tests/runner.sh` uses the real commits `18498db` (no `graphify-setup`) and `a0f4807` (has it). It writes an arms file with three rows, in this order: `read-order 18498db a0f4807 both-at-least 4`, `read-order-heldout 18498db a0f4807 both-at-least 4`, `setup-planning 18498db a0f4807 at-least 4`. It runs the wrapper with `--yes --runs 1` and `STUB_SNAPSHOT_DIR`, as `snaprun` in section 15 does. Map each snapshot `call-N` to its arm and case from the stub log. Assert:
- 17a. In both `a0f4807` read-order snapshots, `scripts/graphify-setup` is byte-equal to `tests/behavior/lib/setup-status-stub` and is executable.
- 17b. In the `a0f4807` `setup-planning` snapshot, which runs after the stubbed cases, `scripts/graphify-setup` is byte-equal to `git show a0f4807:plugins/warden/scripts/graphify-setup` and is executable.
- 17c. No `18498db` snapshot contains `scripts/graphify-setup`.
- 17d. The record holds `- Setup status of <full a0f4807 sha> in read-order: stubbed (ready)` and the same line for `read-order-heldout`. It holds `- Setup status of <full 18498db sha> in read-order: not present` and the same line for `read-order-heldout`. It holds no Setup status line for `setup-planning`.
- 17e. The stub run directly: `status` prints exactly `ready` and exits 0. `setup`, `decline` and no argument each exit non-zero with `stub: only status is supported` on stderr.
- 17f. The total eval count equals 6, one per arm and case. The copies do not add calls.

Existing sections 1–16 keep passing unchanged. Section 15h compares the old wrapper with this one for an old arm, so it must still pass.

Test command: `bash tests/behavior_harness.sh runner`.

**Steps:**
- [ ] Write section 17 (17a–17f), run it, and see 17a, 17d and 17e fail, because the stub and the pins do not exist.
- [ ] Write the stub, and see 17e pass.
- [ ] Add `--setup-status` to `record.py`.
- [ ] Add the per-case copy and the pin arguments to `run-behavior`.
- [ ] Run `bash tests/behavior_harness.sh runner`, and see all sections pass, including 15h.
- [ ] Run `bash tests/behavior_harness.sh`, and show the output.
- [ ] Commit as `fix: stub the setup status in the read-order evals`.

### Task 2: Document the shim and annotate the unreliable records

**Files:**
- Change: `tests/behavior/README.md` (after the paragraph on `read-order` grading)
- Change: `docs/superpowers/changes/2026-10-graphify-setup-in-warden/runs/2026-10-23-4b82f6.md`
- Change: `docs/superpowers/changes/2026-10-graphify-setup-in-warden/runs/2026-10-23-d8ff7d.md`
- Change: `docs/superpowers/changes/2026-10-graphify-setup-in-warden/runs/2026-10-23-e19c49.md`
- Change: `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/2026-11-24-004564.md`
- Change: `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/2026-11-25-9caece.md`

**Depends on:** none

**Model:** cheap tier. The brief gives the full text, and no file holds code.

**Brief:**

In `tests/behavior/README.md`, add one paragraph:
> In the `read-order` and `read-order-heldout` cases, the wrapper runs each arm on its own copy. In that copy, `lib/setup-status-stub` takes the place of `scripts/graphify-setup`. The stub prints `ready` for `status` and refuses every other subcommand. The eval sandbox blocks git, so the real script always prints `unavailable` there, and `setup-check.md` then tells the agent to continue without Graphify. A real session in a repository with a graph prints `ready`. An arm without `graphify-setup` runs unchanged. The record pins `Setup status of <sha> in <case>: stubbed (ready)` or `not present`. The setup cases always use the real script.

At the end of each of the five records, add this section, and keep everything above it unchanged:
> ## Note 2026-11-25
>
> The `read-order` rows from arms with the setup check are unreliable. Those arms are `631ec83`, `061293f`, `a0f4807` and `9f1c0fb`. The eval sandbox blocks git, so `graphify-setup status` printed `unavailable` in every such run. `setup-check.md` then tells the agent to continue without Graphify. All 8 failing runs explored with the next call. The rows are not regraded. See `docs/superpowers/changes/2026-11-read-order-setup-shim/intent.md`.

Each record names only the arms it contains. In `4b82f6`, list `631ec83`. In `d8ff7d` and `e19c49`, list `061293f`. In `004564` and `9caece`, list `a0f4807` and `9f1c0fb`. Keep the rest of the note text the same in all five.

Check: `python3 plugins/superpowers/skills/asd-ste100/scripts/ste-lint.py` on the README and on each record shows no new hard violation. `git diff --stat` shows only additions in the five records.

**Steps:**
- [ ] Add the README paragraph.
- [ ] Add the note to the five records, with the arms each one contains.
- [ ] Run the lint and `git diff --stat`, and show the output.
- [ ] Commit as `docs: describe the read-order setup shim and flag the unreliable rows`.

### Task 3: Hand over the rerun and read the result

**Files:** none committed. One arms file and one run script in `~/.cache/warden-behavior/`.

**Depends on:** 1, 2

**Model:** session

**Brief:** Write `~/.cache/warden-behavior/read-order-shim-arms.conf` with two rows: `read-order 18498db a0f4807 both-at-least 4` and `read-order-heldout 18498db a0f4807 both-at-least 4`. Write `~/.cache/warden-behavior/run-read-order-shim.sh`, which changes into this worktree and runs `tests/behavior/run-behavior --arms` on that file. Hand Nicolai the one-line command `bash ~/.cache/warden-behavior/run-read-order-shim.sh`, to run in a normal terminal. The prompt should show `Agents: 20 (2 cases, 4 arms x 5 runs)`. When he pastes the result:
- Check that the record pins `stubbed (ready)` for `a0f4807` and `not present` for `18498db`, in both cases.
- If `18498db` scores under 4/5 in either case, stop and report to Nicolai. That arm has no setup check, so a low score there means that something else is wrong.
- If `a0f4807` scores under 4/5 in either case, stop and report to Nicolai. The cause would then be the setup-check wording.
- If both arms score at least 4/5 in both cases, commit the record and go on to the final review.

## Waves

| Wave | Tasks | Why |
|---|---|---|
| 1 | 1, 2 | Task 1 owns the wrapper, the record writer, the stub and `runner.sh`. Task 2 owns the README and the five records. |
| 2 | 3 | The rerun needs the finished harness. |

After the last wave: the final review, the fix wave and the scoped re-review, then `finishing-a-development-branch`. There is no spec to reconcile.

## Risks, worst first

1. **The stub leaks into a setup case (Task 1).** Then the setup cases would measure the stub. Every later setup result would be wrong, and nobody would notice. Test 17b checks the setup case after the stubbed cases in the same arm, byte for byte. This is the task with the most risk.
2. **The stub runs on the wrong path.** In a merged arm, the warden script sits at `plugins/superpowers/scripts/graphify-setup`, as the traces show. A stub at another path would leave the real script in place, and the read-order score would stay low. Test 17a checks the exact path.
3. **The copy changes the eval count or the trace paths.** Test 17f checks the count. The trace step reads `tracePath` from the result, so the copy path flows through.
4. **The rerun shows no recovery.** Then the shim works, but the cause is elsewhere. Task 3 stops and reports, as Nicolai asked.
5. **The control arm drops.** If `18498db` scores under 4/5, the eval itself is unstable. Task 3 stops and reports, as Nicolai asked.

Ruled out:
- Swap-and-restore in place: an interrupted run could leave the stub behind (decision OQ1).
- A test-only status override inside `graphify-setup`: it would put test code into the plugin.
- Letting git run in the sandbox: unknown sandbox options, and the fixture would also need a recorded setup.
