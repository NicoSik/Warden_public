# Intent: Setup-check nudge for repos created mid-session

Author: Nicolai Sikora. Date: 2026-11-17. Status: approved.

## Problem
The setup check runs once at SessionStart, and a prose rule asks the agent to repeat it per
repository. When a session starts outside a repo and creates one, the agent does not run the
check. This happened twice, both in sessions that started in `~/Documents/Projects`:

- bed-finder, 2026-10-30. The repo was created 8 minutes after the session started. Specs,
  plans and the build ran without the check. Nicolai asked at 11:29Z.
- middagsplan, 2026-11-10. `create-next-app` ran 9 minutes after the session started.
  Brainstorming had run before the repo existed, and the app was built for 85 minutes with no
  further skill call. Nicolai asked at 17:11Z, and then declined the graph.

A memory rule written after the first miss was loaded in the second session and did not
prevent it. provetid and Pantheon are not cases: both repos existed before their sessions
started, and SessionStart covered them.

## Proposed outcome
When a session creates a repo with `git init`, `git clone` or a scaffolder, that repo is
pending. The agent gets one reminder to run the setup check, at the first of these moments
when `graphify-setup status` no longer prints `small`:

- brainstorming, writing-specs, writing-plans or systematic-debugging starts in the pending repo;
- a `git commit` runs in the pending repo.

The reminder after a commit tells the agent to run the setup check before its next code
exploration, whichever skill is running. Nicolai no longer has to ask whether a graph was made.

## Affected users and systems
- Nicolai, as the only user, in sessions that start outside a repo.
- `plugins/warden/hooks/hooks.json` and a new PostToolUse hook in `plugins/warden`.
- `plugins/warden/scripts/graphify-setup status`, which the hook only reads.
- The lesson session files in `~/.claude/lessons/sessions`, which gain a nudge record.
- The setup and read-order behaviour tests, and the quick-question case.

## Constraints
- The hook is synchronous and has an explicit timeout of about 5 seconds.
- The hook runs `git rev-parse` and `status` only after a create command, after a `git commit`
  in a pending repo, or when one of the four skills starts in a pending repo. Ordinary Bash
  calls stay cheap. A timing test covers this.
- A slow or failed check exits silently, with no nudge.
- The hook never nudges inside a subagent. A live probe confirms that `agent_id` is present in
  a subagent and absent in the main session before the hook relies on it.
- The hook nudges at most once per repo per session.
- A repo whose status is `ready`, `declined` or `small` gets no nudge.
- The relaxed skill condition applies only to repos created mid-session. Existing repos keep
  the rule in `setup-check.md` unchanged.
- A move into an existing repo with `cd` gets no nudge.
- A quick question in an existing repo gets no nudge. The setup cases, the read-order
  behaviour tests and the quick-question case show no change with the hook installed.

## Out of scope
- Nudging after a `cd` into an existing repo. This waits until the report or a manual lesson
  shows such a miss.
- Running the setup itself. The hook only reminds the agent.
- Any change to the SessionStart setup check.

## How we will know it worked
- An offline test shows one nudge per created repo and silence elsewhere.
- Each nudge writes a `{"t":"nudge"}` line to the lesson session file, so `warden-lesson report`
  can show whether a setup call followed.
- Around 2026-12-17: no session has Nicolai asking whether a graph was made, and every nudge
  has a `status` call after it.
- When this merges, the `~/Documents/Projects` memory `graphify-setup-check.md` and its index
  line are deleted, so the hook is the only rule.

## Open questions
- The `Skill` tool's PostToolUse payload has to show the skill name. The live probe checks this
  together with `agent_id`.
- The scaffolder list covers at least `create-next-app`, `npm create`, `npx create-*`,
  `cargo new` and `uv init`. With `--disable-git` the repo appears only at a later `git init`,
  which the hook also catches.
