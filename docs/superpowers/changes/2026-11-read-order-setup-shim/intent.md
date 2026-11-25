# Intent: Read-order eval with a stubbed setup status

Author: Nicolai Sikora. Date: 2026-11-25. Status: approved.

## Problem
Since PR #2 added the setup check, the `read-order` eval scored 15 of 23 valid runs
graph-first, against 25 of 25 before it. Inside the eval sandbox, git is blocked, so
`graphify-setup status` always prints `unavailable`. `setup-check.md` tells the agent to
"continue without Graphify" on that word. All 8 failing runs explored with the very next
call. The eval therefore measures a sandbox artifact, and every `read-order` result since
PR #2 is unreliable. The harness is what every future change is measured with.

## Proposed outcome
In the `read-order` and `read-order-heldout` cases, the setup check prints `ready`, as it
does in a real session in a repository with a graph. The `read-order` score again reflects
whether the agent queries the graph first. Each record states which arms ran with the
stubbed status. The setup cases keep measuring the real script.

## Affected users and systems
- Nicolai, as the person who reads the eval results for every change.
- `tests/behavior/run-behavior` and its offline tests.
- The run records in `docs/superpowers/changes/*/runs/`.
- The warden plugin is not affected. Its files do not change.

## Constraints
- The stub replaces the status script only in the `read-order` and `read-order-heldout`
  cases, in both arms.
- Each stubbed case runs on its own copy of the arm. The harness never swaps the script
  in place and restores it, so an interrupted run cannot leave the stub behind.
- The stub prints `ready` and exits 0 for `status` only. Any other subcommand exits
  non-zero with `stub: only status is supported`.
- In an arm without `graphify-setup`, nothing is stubbed, and that arm's record says
  `setup status: not present`.
- In an arm with a stub, the record says `setup status: stubbed (ready)`.
- The setup cases get the real script byte for byte, including a setup case that runs after
  a stubbed case in the same arm.
- An offline test proves all of the above, including the skip case.
- The `read-order` rows from arms with the setup check get a note that they are unreliable
  because of this artifact, in all five records since PR #2: `4b82f6`, `d8ff7d`, `e19c49`,
  `004564` and `9caece`. They are not regraded.
- No plugin file changes.

## Out of scope
- Changing the `unavailable` wording in `setup-check.md`. That waits for the rerun result.
- Making git work in the eval sandbox.
- Regrading old records.

## How we will know it worked
- The offline test passes.
- A rerun of `read-order` plus `read-order-heldout` compares `a0f4807` (`main`) with
  `18498db` (before PR #2), at both-at-least 4. `main` returns to about 5/5. If it does not,
  the work stops and the result goes to Nicolai, because the cause would then be the
  setup-check wording.

## Decisions
- OQ1: a separate copy of the arm per stubbed case, never swap-and-restore.
- OQ2: annotate the `read-order` rows from setup-check arms in all five records.
- OQ3: the stub supports `status` only.
