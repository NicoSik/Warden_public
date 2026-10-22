# Intent: Merge the whole warden plugin into eval arms

Author: Nicolai Sikora. Date: 2026-10-22. Status: approved.

## Problem
The behavior harness gives an eval arm only `plugins/warden/hooks/`. PR #2 adds a `warden`
skill. Without this change, the setup cases would run without that skill and measure nothing.

## Proposed outcome
An eval arm that contains `plugins/warden` carries every `warden` file in its merged plugin. A
check fails when any `warden` file is missing from the merged arm. This replaces ruling 1 of
`2026-10-graphify-warden-plugin`, which copied `hooks/` only.

## Affected users and systems
- Nicolai only.
- The behavior harness: `tests/behavior/run-behavior` and its offline tests.
- PR #2, which rebases onto this.

## Constraints
- Old arms without `plugins/warden` stay byte-identical.
- A file-name collision still exits 2 and names the path.
- The merged arm keeps the Superpowers manifest. The `warden` files `.claude-plugin/plugin.json`
  and `.claude-plugin/marketplace.json` stay out of the merged arm. The check fails if `warden`
  ships any other manifest file.
- No run touches a real project, the real `~/.claude`, or the git state of this repository.

## Out of scope
- PR #2's setup check and its sandbox fix.
- The namespace check. In the merged arm a `warden` skill loads as `superpowers:<name>`. The
  setup grader counts Bash calls to `graphify-setup ... status`, so the name does not change its
  count. PR #2's smoke check covers the real name: it shows the skill loads as
  `warden:graphify-setup` in the real two-plugin load.

## How we will know it worked
- An offline runner case: a synthetic arm with a `warden` skill, hooks and manifest. Every
  `warden` file except the two manifest files is present and byte-equal in the merged arm.
- An offline case where one `warden` file is missing from the merged arm fails the check.
- The existing runner cases 15a–15c and the full behavior harness pass.
- The harness README states the namespace limit next to the merged-plugin limit.

## Open questions
- None. D1 (manifest) and D2 (namespace) were ruled on 2026-10-22.
