# Spec: setup-check-nudge

Intent: `intent.md`. Date: 2026-11-18. Status: draft.

## Summary

This change adds a synchronous hook to the `warden` plugin. When a session creates a
repository, the hook reminds the main agent once to run the setup check, as soon as the
repository has enough code for a code graph. Repositories that existed before the session
keep the current SessionStart rule unchanged.

Size: 11 requirements from 14 intent items and 15 design decisions. The count is above the
guide of about ten because the safety rule (REQ-9) and the cost rule (REQ-10) each carry their
own proof. The change is still one subsystem.

## Terms

- **The nudge hook** is the new PostToolUse command hook in `plugins/warden/hooks/hooks.json`.
- **The lesson script** is `plugins/warden/scripts/warden-lesson`.
- **The setup script** is `plugins/warden/scripts/graphify-setup`.
- **The status word** is the one word that `<setup script> status` prints.
- **A subagent call** is a hook payload that has an `agent_id` field. **A main-session call**
  is a hook payload without it. REQ-11.1 checks this reading.
- **The repository ID** is the basename of the repository folder, then `#`, then the first 8
  hex characters of the SHA-256 of the resolved `git rev-parse --git-common-dir`.
  Two worktrees of one repository have the same repository ID.
- **The session start** is the creation time (`st_birthtime`) of the file at the payload's
  `transcript_path`.
- **A new repository** is a repository whose `.git` has a creation time after the session start.
- **A pending repository** is a new repository that the nudge hook marked and did not yet
  nudge or drop.
- **The call folder** is the path of a leading `cd <path> &&` in the command, if the command
  has one. Otherwise it is the payload's `cwd`. For a `git -C <path>` command, it is `<path>`.
- **The four skills** are brainstorming, writing-specs, writing-plans and systematic-debugging.
- **The marker** is the per-session file that holds a nudge which waits for delivery.
- **The session log** is the lesson-capture file `<inbox>/sessions/<session_id>.jsonl`.

## Requirements

### Behavior

**REQ-1** The nudge hook MUST mark each new repository that a create command makes as a
pending repository.
  - **REQ-1.1** The nudge hook MUST treat these commands as create commands: `git init`,
    `git clone`, `create-next-app`, `npm create`, `pnpm create`, `yarn create`, `bun create`,
    `npx create-*`, `cargo new`, `cargo init` and `uv init`.
  - **REQ-1.2** After a create command, the nudge hook MUST check the repository of the call
    folder and each direct subdirectory of the call folder.
  - **REQ-1.3** The nudge hook MUST mark a checked repository only when it is a new repository.
  - **REQ-1.4** The nudge hook MUST NOT mark a repository whose `.git` is older than the
    session start.
  - **REQ-1.5** If the session start or a `.git` creation time is not available, the nudge
    hook MUST mark nothing for that call.
  - **REQ-1.6** The nudge hook MUST mark pending repositories in main-session calls and in
    subagent calls.
  *Proof: T1, T2 and T3 in `tests/warden_setup_nudge.sh`.*
  *Source: intent outcome paragraph 1. Design decisions D3 and Q1 = C.*

**REQ-2** The nudge hook MUST run the status check for a pending repository only at a trigger.
  - **REQ-2.1** A `git commit` in a pending repository MUST trigger the status check for that
    repository, in main-session calls and in subagent calls.
  - **REQ-2.2** The start of one of the four skills MUST trigger the status check for every
    pending repository of the session, in main-session calls only.
  - **REQ-2.3** If the status word is `small`, the repository MUST stay a pending repository.
  - **REQ-2.4** If the status word is `ready` or `declined`, the repository MUST stop being a
    pending repository, and the nudge hook MUST NOT nudge it in that session.
  - **REQ-2.5** If the status word is `ask`, `build` or `no-cli`, the nudge hook MUST nudge
    the repository as REQ-3 states.
  *Proof: T1, T2, T4, T6, T7 and T8.*
  *Source: intent outcome paragraph 1 and the constraint on the expensive check. Decisions D2,
  D4 and the OQ1 ruling.*

**REQ-3** The nudge hook MUST deliver at most one nudge per repository per session, and only
to the main agent.
  - **REQ-3.1** The nudge hook MUST deliver a nudge only as `additionalContext` output of a
    main-session call.
  - **REQ-3.2** If a subagent call reaches REQ-2.5, the nudge hook MUST write the marker and
    print nothing.
  - **REQ-3.3** The next main-session Bash or Skill call MUST deliver the nudge in the marker
    and remove the marker.
  - **REQ-3.4** If two main-session calls find the same marker at the same time, exactly one
    of them MUST deliver the nudge.
  - **REQ-3.5** If one call has several repositories to nudge, the nudge hook MUST deliver
    them in one `additionalContext` message.
  *Proof: T1, T5, T6 and T15.*
  *Source: intent constraints "never nudges inside a subagent" and "at most once per repo per
  session". Decision D5.*

**REQ-4** The nudge text MUST tell the main agent to run the setup check for the named
repository, and it MUST give the exact command.
  - **REQ-4.1** The command MUST have the form `cd <repo> && <setup script> status`, with both
    paths quoted by `shlex.quote`.
  - **REQ-4.2** A nudge from REQ-2.2 MUST tell the agent to run the check before the first
    code exploration in the skill that started.
  - **REQ-4.3** A nudge from REQ-2.1 MUST tell the agent to run the check before its next
    code exploration in that repository, or before it dispatches the next subagent into it,
    whatever skill is running.
  - **REQ-4.4** The nudge text MUST tell the agent to act on the printed word as the Setup
    check section of the session context says.
  - **REQ-4.5** The nudge text MUST NOT contain the status word.
  - **REQ-4.6** The template `plugins/warden/hooks/setup-nudge.md` MUST contain each of
    `{{REPO}}` and `{{GRAPHIFY_SETUP}}` exactly once. If it does not, the nudge hook MUST
    print nothing and keep the repository pending.
  *Proof: T1, T4 and T12. A reviewer reads `setup-nudge.md` for REQ-4.2 to REQ-4.5.*
  *Source: intent outcome paragraph 2 and the constraint on the relaxed skill condition.
  Decision D8.*

**REQ-5** The nudge hook MUST NOT change the behaviour for a repository that existed before
the session.
  - **REQ-5.1** The nudge hook MUST NOT nudge after a `cd` into a repository that is not new.
  - **REQ-5.2** A quick question in a repository that is not new MUST get no nudge and no
    marker.
  - **REQ-5.3** This change MUST NOT edit `plugins/warden/hooks/setup-check.md` or the
    SessionStart output of `plugins/warden/hooks/code-map`.
  *Proof: T3 and T9. `git diff main -- plugins/warden/hooks/setup-check.md
  plugins/warden/hooks/code-map` prints nothing. The `setup-quick-question` rerun of REQ-11.2.*
  *Source: intent constraints on existing repos, `cd` and the quick question. Out of scope
  items 1 and 3.*

### Data

**REQ-6** The nudge hook MUST write lesson records that let `warden-lesson report` pair each
nudge with a later setup call.
  - **REQ-6.1** For each nudge it delivers, the nudge hook MUST append one line to the session
    log with the fields `t` = `nudge`, `ts`, `repo`, `trigger`, `via` and `word`.
  - **REQ-6.2** `trigger` MUST be `skill` or `commit`. `via` MUST be `direct` or `marker`.
  - **REQ-6.3** For each Bash call whose command runs the setup script, the nudge hook MUST
    append one line with the fields `t` = `setup-call`, `ts` and `repo`. This applies to
    main-session calls and to subagent calls.
  - **REQ-6.4** The `repo` field MUST hold the repository ID of the call folder.
  - **REQ-6.5** A record MUST NOT contain a filesystem path or any command text.
  - **REQ-6.6** If lesson capture is off, the nudge hook MUST write no record and MUST still
    deliver nudges.
  *Proof: T10, T11 and T18.*
  *Source: intent measure "a nudge line in the lesson session file". Decisions D6 and D7.*

**REQ-7** The nudge hook MUST keep its per-session state outside the lesson inbox.
  - **REQ-7.1** The state MUST live in `~/.claude/warden/nudge/`, in files named by the
    sanitized `session_id`.
  - **REQ-7.2** Parallel hook runs MUST NOT lose a pending mark or a nudged mark.
  - **REQ-7.3** When the nudge hook writes state, it MUST remove state files, markers and
    claimed markers older than 7 days.
  *Proof: T15, T16 and T18.*
  *Source: intent constraint "at most once per repo per session". Decisions D1 and D10.*

### Interface

**REQ-8** `plugins/warden/hooks/hooks.json` MUST register the nudge hook as a synchronous
PostToolUse command hook.
  - **REQ-8.1** The entry MUST use the matcher `Bash|Skill` and `"timeout": 5`.
  - **REQ-8.2** The entry MUST NOT set `async` to `true`.
  - **REQ-8.3** This change MUST NOT change the existing lesson-capture entries.
  - **REQ-8.4** If `WARDEN_NUDGE_OFF` is `1`, the nudge hook MUST exit before it reads
    any state.
  *Proof: T13 and T19.*
  *Source: intent constraint "synchronous, explicit timeout of about 5 seconds". Decision D9.*

### Operations

**REQ-9** The nudge hook MUST NOT fail, block or delay a tool call past its time limit.
  - **REQ-9.1** The nudge hook MUST exit 0 on every path.
  - **REQ-9.2** If a check fails or is slow, the nudge hook MUST print nothing and keep the
    repository pending.
  - **REQ-9.3** Each `git rev-parse` run MUST stop after 1 second. Each status check MUST stop
    after 3 seconds. All status checks of one hook run MUST stop after 4 seconds in total.
  - **REQ-9.4** The nudge hook MUST print its output once, at the end of the run.
  - **REQ-9.5** Bad JSON or a missing `session_id` MUST give a silent exit 0.
  *Proof: T14 and T17.*
  *Source: intent constraint "a slow or failed check exits silently". Decision D9.*

**REQ-10** A Bash or Skill call with no trigger MUST cost the nudge hook no Python and no git.
  - **REQ-10.1** The median CPU time (user + sys) of 20 runs on a payload with no trigger
    MUST be under 20 ms.
  - **REQ-10.2** The median CPU time of 20 runs on a `git commit` payload in a repository that
    is not pending MUST be under 100 ms.
  *Proof: the timing test in `tests/warden_setup_nudge.sh`, which measures `RUSAGE_CHILDREN`.*
  *Source: intent constraint "ordinary Bash calls stay cheap. A timing test covers this."
  Decision D11.*

**REQ-11** The change MUST pass three live checks.
  - **REQ-11.1** Before the build relies on payload fields, a headless probe MUST record
    whether `agent_id` is present in a subagent call and absent in a main-session call (P1),
    whether a Skill payload names the skill (P2), and whether a subagent call carries the
    main session's `session_id` (P3). The probe MUST NOT edit `~/.claude/settings.json`.
  - **REQ-11.2** The behaviour cases `setup-quick-question`, `setup-planning` and `read-order`
    MUST show no change against `main` with the nudge hook in the merged arm.
  - **REQ-11.3** After the merge, a session started in `~/Documents/Projects` that creates a
    repository, commits 20 or more source files and gets a nudge MUST show a `nudge` line
    followed by a `setup-call` line in `warden-lesson report`.
  *Proof: the probe results in `plan.md`. The behaviour run output. The post-merge check in
  the PR test plan.*
  *Source: intent constraints on the probe and the behaviour tests, and the intent measures.
  Decisions D12 and D13.*

## Non-goals

- A nudge after a `cd` into an existing repository. This waits until the report or a manual
  lesson shows such a miss (decision Q1 = C).
- Running the setup itself. The nudge hook only reminds the agent.
- Any change to the SessionStart setup check or to `setup-check.md`.
- A new behaviour case for a repository created mid-session. T1 to T5 cover that path, and a
  live case needs a long session to pass 20 source files.
- The change from wall-clock to CPU time in the existing lesson timing tests. That is a
  separate leftover.

## Constraints applied

Rules and area guides:

- `CLAUDE.md` (root): test first, a pass-or-fail check for every change, reuse before you
  create. The nudge records reuse the session log path and line writer of the lesson script.
  The template check reuses the single-placeholder pattern of `hooks/code-map`.
- `rules/instruction-files.md`: the nudge text is hook context, so it lives in a template
  beside `setup-check.md`, not in an always-on rule.
- `tests/no_machine_content.sh`: no machine path in a committed file. The nudge text gets the
  setup script path from the plugin root at run time.
- `docs/decisions/RULES-AND-HOOKS.md`: option 3 for the branch guard records the pattern this
  hook uses, exit 0 with `additionalContext`, never a block.

Policy skills: this is a configuration and tooling repository with no domain. REQ-6.5 is a
privacy measure from the design decisions, not a policy skill.

## Open questions carried from intent

- **Still open, answered by REQ-11.1 in plan task 1.** Whether the Skill tool's PostToolUse
  payload names the skill (P2). If P1 or P3 fails, the build stops, and Nicolai decides.
- **Answered by REQ-1.1.** The create command list. A scaffolder run with `--disable-git`
  makes no `.git`, so REQ-1.3 marks nothing until the later `git init`. Extra create commands
  are harmless, because REQ-1.3 marks only a new repository.

## Design notes

Decisions of 2026-11-17 and 2026-11-18 that the requirements cite:

- **Q1 = C.** Only repositories created mid-session get a nudge.
- **OQ1 ruling.** A `git commit` re-checks a pending repository until it leaves `small`. The
  relaxed skill condition applies only to new repositories.
- **D1.** A bash prefilter reads each payload. It hands a call to `warden-lesson nudge` only
  on a trigger word, a marker, or a run of the setup script.
- **D2.** The Skill trigger checks every pending repository, because the main session often
  stays in a folder that is not a repository.
- **D3.** The session start, not a fixed time window, decides whether a repository is new.
- **D4.** `no-cli` gets a nudge, so the agent runs `notice`.
- **D5.** A subagent commit writes the marker. The main session delivers it.
- **D6.** `setup-call` records come from main-session calls and from subagent calls.
- **D7.** Records identify a repository by its repository ID, never by its path.
- **D8.** Each placeholder appears exactly once. T12 uses a path with a space and a quote.
- **D9.** A 5-second hook timeout. Any slow or failed check is silent.
- **D10.** The 7-day cleanup also removes claimed markers.
- **D11.** The timing test measures CPU time.
- **D12.** Nicolai starts the behaviour reruns. The PR test plan holds the post-merge check.
- **D13.** The live probe covers P1, P2 and P3.

The status check counts tracked source files with `git ls-files` and prints `small` under 20.
A new repository therefore stays pending until the agent commits about 20 source files. For
this reason, the commit is the re-check trigger.
