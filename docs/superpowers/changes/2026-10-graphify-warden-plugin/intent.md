# Intent: Move Graphify into a Warden plugin

Author: Nicolai Sikora. Date: 2026-10-22. Status: approved.

## Problem
The Code Map rule lives in the vendored Superpowers plugin, in
`using-superpowers/SKILL.md` and `subagent-driven-development/implementer-prompt.md`.
PR #2 adds `graphify-setup` to the same skill. Every refresh from obra/superpowers
must carry these Warden-only edits across by hand, and the fork drifts from upstream.

## Proposed outcome
Graphify behavior lives in a Warden-level plugin named `warden`, which `install.sh`
registers next to Superpowers. The vendored Superpowers plugin has no Graphify
content. An agent in a repo with `graphify-out/graph.json` behaves the same as
before the move.

## Affected users and systems
- Nicolai only.
- `plugins/superpowers/`: loses the Code Map sections.
- A new `warden` plugin under `plugins/`.
- `install.sh`, `uninstall.sh`, `README.md`.
- The behavior harness (`tests/behavior/run-behavior`): it loads both plugins as
  one merged scratch plugin per arm, because `claude plugin eval` loads one plugin.
  It also gates the baseline arm for a no-regression row. That gate is built
  test-first, and the existing arms files and run records still grade exactly as
  before.
- PR #2: rebases onto the new plugin after this change merges.

## Constraints
- Existing arms keep working: old commits still evaluate as before.
- No run touches a real project, the real `~/.claude`, or Warden's git state.
- The Code Map text the agent sees does not change in wording.

## Out of scope
- PR #2's setup check and its sandbox fix. Those come next, on PR #2.
- Lesson capture (P1) and anything after it.
- Changes to the Code Map rule's wording or behavior.

## How we will know it worked
- read-order: baseline `7ac111f` and candidate (the move commit) both reach
  >= 4/5. This is a no-regression check. It does not reuse the "baseline below
  4/5" gate.
- read-order-heldout: candidate reaches >= 4/5.
- `grep -ri graphify plugins/superpowers` returns nothing.
- An offline check shows that the Code Map rule still reaches subagents after the
  move. No eval case covers subagents, so this check is the only evidence.
  The approaches step picks the mechanism.
- A manual smoke check with both plugins really installed: both SessionStart
  hooks run, the Warden skill loads, no name collisions. The PR body records the
  result and states that the eval proof covers the merged plugin, not the real install.
- After PR #2 rebases: all three setup cases plus read-order rerun with its new
  head as the candidate.

## Open questions
- How the subagent rule reaches subagents once `implementer-prompt.md` no longer
  carries it.
