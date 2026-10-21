# Handoff: Code Map file listing (paused 2026-10-21)

## Where things are
- Worktree `~/Warden_public-code-map`, branch `feature/code-map-file-listing`, from `fork/main` at `7d972fa`.
- Committed locally, not pushed: `intent.md` (approved) and this file.
- Remote rule: push and open PRs only on `NicoSik/Warden_public` (remote `fork`). Never `BlastBlastBlast`.
- Path: bounded. The next step is a short design in chat, then approval, then superpowers:writing-plans.
- Not done yet: no design approval, no plan, no code, no run.
- Delete this file before the PR opens.

## Proposed design (needs Nicolai's approval)
D1. **Grader, test-first.** In `tests/behavior/tests/traces/`, add one trace per allowed check in the intent's list, each followed by `graphify query` (want 1). Add traces for `tree`, `wc -l app/x.ts`, and `ls` of the repo root (want 0). In `lib/graph_first.py`, treat a segment as graph-output work when every path token is under `graphify-out` with or without a trailing `/`. Treat `cd graphify-out` as moving into graph output for the rest of the command. Add `tree` and `wc` to `EXPLORE_CMD`. Commit. The grader is frozen after this commit.

D2. **Held-out case.** Add `tests/behavior/evals/read-order-heldout/` as a copy of `read-order/` with a new prompt. The prompt asks a different code question on the same fixture, for example: "Find where the product page reads the session cookie, and list the files a change to the cookie format would touch. Do not edit files." Keep the "You cannot reach your human partner" paragraph. Commit. The prompt is frozen after this commit.

D3. **Harness flags, test-first in `tests/behavior/tests/runner.sh`.**
- `--arms FILE` replaces `evals/arms.conf`. The default stays `evals/arms.conf`.
- `--record-dir DIR` replaces the record folder. The default stays the old folder.
- A baseline SHA of `-` runs the candidate arm only, and the row is report only.
- After grading, print each read-order run's first commands to the terminal only. Never write them into the record.

D4. **Wording.** Change step 1 in both copies to the same text: `plugins/superpowers/skills/using-superpowers/SKILL.md` and `plugins/superpowers/skills/subagent-driven-development/implementer-prompt.md`. Draft: "Run `graphify query \"<question>\"` before you list, search or read any source file. Listing means `ls`, `git ls-files`, `tree` or `find`. Searching means `grep` or `rg`. Before the query, you may only check `graphify-out/` itself: list it, test that it exists, or read a file in it."

D5. **Arms file for this change.** `docs/superpowers/changes/2026-10-code-map-file-listing/arms.conf`:
```
read-order 7d972fa <wording-commit-sha> at-least 4
read-order-heldout - <final-wording-commit-sha> at-least 4
```
The candidate SHA is the commit that holds the D4 wording. Write the arms file in a later commit.

## Run order
1. Gate run on Sonnet. Nicolai starts it, because it asks for `y` and uses his plan:
   `tests/behavior/run-behavior --arms docs/superpowers/changes/2026-10-code-map-file-listing/arms.conf --record-dir docs/superpowers/changes/2026-10-code-map-file-listing/runs --case read-order --model sonnet`
2. Pass = candidate at least 4/5 and baseline below 4/5. If the baseline reaches 4/5 or more, stop and report: the case cannot show the change.
3. If the candidate fails, revise D4 from the printed first commands, commit, update the candidate SHA, and rerun. Stop after 3 gate runs.
4. After the gate passes, run the held-out case once: `--case read-order-heldout`. Report the count, do not gate on it.
5. Push to `fork`, open the PR on `NicoSik/Warden_public`, and hand Nicolai the squash-merge command.

## Rules learned
- Never remove `/private/tmp/e-*` while a `run-behavior` or `claude plugin eval` process runs. Check `ps` first. Those dirs need `chmod -R u+rwx` before `rm -rf`.
- Thresholds assume 5 runs per arm. Fewer runs always FAIL the at-least rows.
- The repo's pre-commit scrub refuses any literal `/home/<name>` or `/Users/<name>` text, test files included. Build such paths from `$HOME`.
- For read order, `score` and `passed` in a record come from the eval's `bash-used` grader. `graph_first` carries the read-order result.
