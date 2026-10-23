# Intent: Graphify setup in the warden plugin, failing cleanly in a sandbox

Author: Nicolai Sikora. Date: 2026-10-23. Status: approved.

## Problem
PR #2's setup check lives in the vendored Superpowers plugin. In a sandboxed session on
macOS it cannot run: the git launcher, the home-folder binary and `.git/config` writes are
blocked. Today it then prints a wrong message ("not inside a git work tree") or nothing,
and setup can leave a built graph and an edited `.gitignore` behind.

## Proposed outcome
The setup check and its script live in the warden plugin, as the skill
`warden:graphify-setup`. The warden SessionStart hook tells the main session to use it
before the first code exploration. Subagents keep receiving the Code Map rule alone.
Before any write, `graphify-setup` checks that git runs and that the graphify binary runs.
In `setup`, the `.git/config` write comes first, so a failure there leaves nothing behind.
Rollback covers failures after that write. When a check fails, `status` prints
`unavailable`, every command prints one clear message, and nothing changes. Unsandboxed
sessions behave as PR #2 does today. No sandbox setting changes.

## Affected users and systems
- Nicolai only. He does not use the sandbox in his own sessions.
- `plugins/warden`: a new skill, a second SessionStart file, the hook script.
- `plugins/superpowers`: loses PR #2's setup-check text and script.
- The `2026-10-graphify-warden-plugin` spec: REQ-1.2 is amended for SessionStart only.
- PR #2: rebased onto the warden plugin. Its known-issue section becomes a
  graceful-failure note.

## Constraints
- No sandbox setting changes. Setup does not have to work inside a sandbox.
- No partial state: when a command fails, the repository and the machine look as they did
  before the command ran.
- SubagentStart injects `code-map.md` alone, byte for byte, as today.
- The Superpowers plugin carries no Graphify content.

## Out of scope
- Making setup work inside a sandbox.
- Changes to the setup flow: ask once, a decline is final, small repositories are skipped,
  the install notice appears once.

## How we will know it worked
- Offline tests simulate each failure: git does not run, the graphify binary does not run,
  the `.git/config` write fails, and a later step fails. Each one shows one message,
  `unavailable` from status where it applies, and an unchanged repository.
- Rerun on the new PR #2 head: the three setup cases plus read-order. The eval sandbox
  blocks git, so the setup runs also show the agent receiving `unavailable`.
- PR #2's smoke check shows the skill loading as `warden:graphify-setup` in the real
  two-plugin load.

## Decisions
- 2026-10-22: the trigger reaches the agent through a second SessionStart file,
  `setup-check.md`. Only SessionStart injects it.
- 2026-10-23: the `.git/config` write goes first in setup. A set-then-unset of
  `warden.probe` is the fallback only if the config write cannot go first.
- 2026-10-23: the rebased branch replaces PR #2's remote branch with
  `--force-with-lease`. Afterwards, the old worktree that holds PR #2's branch is removed
  or reset.

## Open questions
- None from the interview. The spec settles the config key name and how existing
  `superpowers.graphify` values carry over.

## Decisions after approval
- 2026-10-23: warden has no `graphify-setup` skill. `hooks/setup-check.md` keeps PR #2's
  direct instruction and actions. The SessionStart hook replaces the one placeholder
  `{{GRAPHIFY_SETUP}}` with the quoted absolute path of `plugins/warden/scripts/graphify-setup`.
  This keeps the eval and the real install on the same text. The Proposed outcome's skill
  name `warden:graphify-setup` no longer applies.
- 2026-10-23: when `git --version` fails, status prints `unavailable` with the one message.
  When git runs but the directory is not a git work tree, PR #2's behavior stays.
