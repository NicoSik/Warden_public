# Spec: lessons-ledger-weekly-report

Intent: `intent.md`. Date: 2026-11-26. Status: approved.

## Summary

This change gives each failure class in the lesson inbox a recorded decision: open, fixed,
verified or ignored. The report then shows fixed classes that came back before all other rows.
A weekly launchd job writes the report to a file and shows a macOS notification only when
a fixed class recurs or a flagged signature has no decision.

Size: 10 requirements from 20 intent items (6 outcome paragraphs, 7 constraints, 6 resolved
questions, 1 open question) and the four design sections approved on 2026-11-26.

## Terms

- **The lesson script** is `plugins/warden/scripts/warden-lesson`.
- **The ledger module** is the Python file beside the lesson script that holds the ledger,
  `mark`, `weekly` and `schedule` code.
- **The inbox** is the folder that `inbox()` returns, `~/.claude/lessons` by default.
- **The ledger** is the file `<inbox>/ledger.jsonl`.
- **An entry** is the latest ledger line for one slug. Earlier lines for that slug are its
  history.
- **A slug** is a kebab-case name that identifies an entry.
- **The normalized signature** is a signature after `_norm`, which replaces every digit run
  with `N`. The report groups rows by it today.
- **A sig entry** is an entry of kind `sig`. It holds a regex.
- **A nudge entry** is an entry of kind `nudge`. It holds no regex.
- **A session file** is one file `<inbox>/sessions/<session_id>.jsonl`.
- **The first record** of a session file is its first line that parses, of any type: an
  edit, a failure, a test pass, a nudge or a setup-call.
- **The session day** is the local calendar date of the first record's `ts`.
- **The fix day** is the `fixed_on` date of an entry.
- **An after-fix session** is a session file whose session day is later than the fix day.
- **A recurring entry** is a fixed or verified entry that matches a row or a nudge from at
  least one after-fix session.
- **An unacknowledged signature** is a flagged report row that no entry matches.
- **The weekly folder** is `<inbox>/weekly/`.
- **The main checkout** is the folder that the resolved `~/.claude/bin` symlink sits in.

## Requirements

### Behavior

**REQ-1** The `mark` command MUST create or update an entry by appending one line to the ledger.
  - **REQ-1.1** The `mark` command MUST accept the statuses `open`, `fixed`, `verified` and
    `ignored`, and no other status.
  - **REQ-1.2** For a new slug, the `mark` command MUST require `--match REGEX` or `--nudge`.
  - **REQ-1.3** For an existing slug, the `mark` command MUST copy each field that the call
    does not give from the current entry.
  - **REQ-1.4** The `mark` command MUST refuse a `fixed` or `verified` entry without a fix day.
  - **REQ-1.5** The `mark` command MUST refuse an `ignored` entry without a note.
  - **REQ-1.6** The `mark` command MUST refuse a regex that `re.compile` rejects.
  - **REQ-1.7** On a refusal, the `mark` command MUST exit 2 and MUST NOT write a line.
  - **REQ-1.8** After a write, the `mark` command MUST print the number of matching
    signatures, sessions and after-fix sessions. The count includes hidden rows.
  - **REQ-1.9** After a write, the `mark` command MUST print at most 10 matching rows,
    then `+N more` for the rest.
  - **REQ-1.10** The `mark` command MUST print a warning when the new regex matches a row
    that another entry matches. The warning names that entry. The write still happens.
  - **REQ-1.11** `mark <slug> --history` MUST print every ledger line for the slug, oldest first.
  - **REQ-1.12** `mark --list` MUST print the current entry for each slug.
  - **REQ-1.13** The `mark` command MUST refuse a line when the secret scrub or the 512-byte
    cap changes a field other than the note. (Ruling P2, 2026-11-26.)
  - **REQ-1.14** The `mark` command MUST print a warning when the secret scrub or the cap
    changes only the note. The write still happens. (Ruling P2, 2026-11-26.)
  *Proof: T4, T5, T6 and T7 in the ledger tests.*
  *Source: outcome paragraphs 1 and 2. Design section 1.*

**REQ-2** The ledger module MUST match entries to report rows and nudges by these rules.
  - **REQ-2.1** A sig entry MUST match a row when `re.search` finds its regex in the row's
    normalized signature.
  - **REQ-2.2** A nudge entry MUST match each nudge that has no later setup-call for the same
    repository in its session file.
  - **REQ-2.3** When two entries match one row, the entry with the latest `ts` MUST win.
  *Proof: T13 and T15.*
  *Source: design section 1, the answer "pattern per entry" in the interview, design section 2.*

**REQ-3** The ledger module MUST count a match as after the fix only when it comes from an
after-fix session.
  - **REQ-3.1** A session whose first record falls on the fix day or earlier MUST NOT count,
    also when its matching failure falls on a later day.
  *Proof: T12, and T18b for the notification.*
  *Source: the open question "merge-day edge". Design section 1, approved with the first-record rule.*

**REQ-4** The `report` command MUST show the ledger state of each row.
  - **REQ-4.1** When at least one recurring entry exists, the first section of the report
    MUST be "Fixed but recurring". When none exists, the report MUST NOT print the section.
  - **REQ-4.2** The section MUST hold one header line per recurring entry, with the slug,
    the status, the PR, the fix day and the number of after-fix sessions.
  - **REQ-4.3** Under each header, the section MUST list the matching rows or nudges, indented.
  - **REQ-4.4** The section MUST show a matching row even when a hide reason applies to it.
  - **REQ-4.5** A row in the section MUST NOT appear again in the main list.
  - **REQ-4.6** A row that matches an open, fixed or verified entry MUST end with
    `ledger(<slug>:<status>)` in the main list.
  - **REQ-4.7** The report MUST hide a row that matches an ignored entry, and MUST count it
    under the hide reason `ignored`, after the existing reasons.
  - **REQ-4.8** `report --all` MUST show the ignored rows with `hidden(ignored)`.
  - **REQ-4.9** With a missing or empty ledger, the report MUST print the same bytes as before
    this change.
  - **REQ-4.10** The report MUST skip a ledger line whose regex does not compile, and MUST end
    with `ledger: N entries skipped (bad regex: <slugs>)`.
  - **REQ-4.11** When the ledger cannot be read, the report MUST print the rows without ledger
    data and end with `ledger: unreadable`.
  - **REQ-4.12** The report MUST NOT exit non-zero because of the ledger.
  *Proof: T10, T11, T14 and T16.*
  *Source: outcome paragraph 3, the constraint on existing output. Design section 2, with the
  grouping change.*

**REQ-5** The `weekly` command MUST write the report to a file and MUST notify only when there
is something new to act on.
  - **REQ-5.1** The `weekly` command MUST write the report to `<weekly folder>/report-YYYY-MM-DD.txt`
    through a temporary file and a rename. A second run on one day replaces that day's file.
  - **REQ-5.2** The `weekly` command MUST count R as the number of recurring entries, not rows.
  - **REQ-5.3** The `weekly` command MUST count U as the number of unacknowledged signatures.
  - **REQ-5.4** When R + U > 0, the `weekly` command MUST show one notification with R, U and
    the path of the report file.
  - **REQ-5.5** The notification MUST NOT hold signature text.
  - **REQ-5.6** When R + U = 0, the `weekly` command MUST NOT show a notification.
  - **REQ-5.7** The `weekly` command MUST keep the 12 newest report files and delete older ones.
  - **REQ-5.8** The `weekly` command MUST NOT delete any file in the weekly folder that is
    not a `report-*.txt` file.
  - **REQ-5.9** The `weekly` command MUST write `<weekly folder>/last-run` at the end of each
    run, with the time, the report path, R, U, whether it notified, and the error if a step failed.
  - **REQ-5.10** The `weekly` command MUST exit 1 when it cannot write the report or when the
    notification command fails.
  *Proof: T17, T18, T18b, T19, T20 and T21.*
  *Source: outcome paragraph 4, the notification answer in the interview. Design section 3,
  with counting by entry.*

**REQ-6** The `status` command MUST show the state of the weekly run and of the schedule.
  - **REQ-6.1** The `status` command MUST print its existing four lines unchanged, then a
    `weekly:` line, then a `schedule:` line.
  - **REQ-6.2** The `weekly:` line MUST show the last run time, R, U and whether it notified.
  - **REQ-6.3** The `weekly:` line MUST say `never run` when `last-run` does not exist.
  - **REQ-6.4** The `weekly:` line MUST end with `STALE` when the last run is more than 8 days old.
  - **REQ-6.5** The `weekly:` line MUST show the error that `last-run` records.
  - **REQ-6.6** The `schedule:` line MUST show the first state that applies, in this order:
    `not installed`, `broken (script missing: <path>)`, `broken (interpreter missing: <path>)`,
    `installed, Monday 09:15, notification unconfirmed`, `installed, Monday 09:15`.
  *Proof: T26.*
  *Source: outcome paragraph 5, the interview answer "silence can't hide a broken job". Design section 3.*

### Data

**REQ-7** Only the `mark` command MUST write the ledger, and only by appending.
  - **REQ-7.1** The `mark` command MUST create the ledger with mode `0600` and MUST write
    each line with the single append write of the inbox writer. (Ruling P1, 2026-11-26.
    The inbox writer holds no lock.)
  - **REQ-7.2** The `mark` command MUST pass the note through the secret scrub of the inbox.
  - **REQ-7.3** Retention MUST NOT delete or change the ledger, at any file age.
  - **REQ-7.4** The `report`, `weekly` and `status` commands MUST NOT change the ledger or any
    file in the inbox outside the weekly folder.
  - **REQ-7.5** The inbox record format MUST NOT change.
  *Proof: T8 and T9.*
  *Source: constraints 1 to 4, the resolved question on append-only. The interview answer on the
  ledger home.*

### Interface

**REQ-8** The capture hook MUST NOT load the ledger module.
  - **REQ-8.1** The lesson script MUST load the ledger module with `importlib` from the
    resolved real path of the lesson script.
  - **REQ-8.2** The `mark` and `report` commands MUST work through the `bin/warden-lesson`
    wrapper reached through a symlink, under `python3 -I`.
  - **REQ-8.3** The hook timing test MUST still pass.
  *Proof: T1, T2 and T3.*
  *Source: the constraint "the capture hook stays fast". Approach A1, approved with these additions.*

### Operations

**REQ-9** The `schedule` command MUST install and uninstall the weekly launchd agent.
  - **REQ-9.1** `schedule install` MUST take the script path as
    `<main checkout>/plugins/warden/scripts/warden-lesson`.
  - **REQ-9.2** `schedule install` MUST refuse when `<main checkout>/.git` is a file, and the
    message MUST say the checkout is a git worktree.
  - **REQ-9.3** `schedule install` MUST refuse when `~/.claude/bin` does not exist.
  - **REQ-9.4** `schedule install` MUST use the unresolved `python3` path from PATH as the
    interpreter, and MUST refuse when PATH has no `python3`.
  - **REQ-9.5** `schedule install` MUST write a plist that runs `<python3> -I <script> weekly`
    every Monday at 09:15.
  - **REQ-9.6** `schedule install` MUST unload a loaded agent before it loads the new plist, so
    a second install leaves one agent.
  - **REQ-9.7** After the bootstrap, `schedule install` MUST send one test notification
    through the launchd agent with `launchctl kickstart`, not from the terminal.
    (Ruling, 2026-11-26.)
  - **REQ-9.8** When stdin is a terminal, `schedule install` MUST ask whether the test
    notification appeared, and a `y` MUST record the confirmation.
  - **REQ-9.9** When stdin is not a terminal, `schedule install` MUST print the
    `warden-lesson schedule confirm` command and exit 0.
  - **REQ-9.10** `schedule confirm` MUST record the confirmation.
  - **REQ-9.11** `schedule uninstall` MUST unload the agent and delete the plist, and MUST keep the
    weekly folder.
  - **REQ-9.12** `schedule uninstall` MUST exit 0 when the plist does not exist.
  - **REQ-9.13** The repository MUST NOT contain a plist or a home path.
  - **REQ-9.14** In the test mode, the agent's run MUST send only the test notification and
    MUST NOT write a report, `last-run` or any other file.
  - **REQ-9.15** `schedule install` MUST ask the confirmation question only after the agent
    ran the test mode.
  - **REQ-9.16** When the agent does not run the test mode within 10 seconds,
    `schedule install` MUST exit 1 and say that the agent did not run.
  - **REQ-9.17** A test-mode request older than 5 minutes MUST NOT stop a normal weekly run.
  *Proof: T22, T22b, T22c, T23, T24, T25 and T27.*
  *Source: resolved questions on `schedule` and the run time. Design section 3 with the three fixes.*

**REQ-10** After the merge, the ledger MUST hold these four entries, written with `mark`
before `schedule install` runs.

| Slug | Kind | Regex | Status |
|---|---|---|---|
| `zsh-equals-word` | sig | `^\(eval\):N: \S+ not found$` | verified, PR 11, fix day 2026-11-10 |
| `zsh-include-glob` | sig | `^\(eval\):N: no matches found: \S*--include=` | verified, PR 11, fix day 2026-11-10 |
| `setup-check-miss` | nudge | none | fixed, PR 13, fix day 2026-11-25 |
| `hedges-output-line` | sig | `^Hedges<path> \(may, might, could\)` | ignored |

  - **REQ-10.1** The `zsh-include-glob` note MUST name its evidence: 0 occurrences in the 9
    sessions from 2026-11-10 to 2026-11-17.
  - **REQ-10.2** The `setup-check-miss` note MUST say that the live check is pending, and that
    the entry cannot see a miss where no nudge fired.
  - **REQ-10.3** The `hedges-output-line` note MUST say that the row is a script's output
    line, not a failure.
  *Proof: the `mark --list` output after seeding. `mark` prints 1 match for `zsh-equals-word`
  and 0 for `zsh-include-glob`.*
  *Source: outcome paragraph 6, the corrections to the intent, the post-merge order.*

## Non-goals

- Email, Slack or any message that leaves the Mac. The inbox stays on this machine.
- Cloud routines or a Claude session cron. Neither one can read the inbox every week.
- Automatic status changes. A decision in the ledger comes from a person.
- Committing the ledger to the repository. It describes one machine's inbox.
- Running `install.sh` on this Mac. The settings split comes first.
- A separate backup of the ledger. The append-only history is the backup.
- A notification that opens the report file. `osascript` cannot attach a click action.

## Constraints applied

Rules and area guides:

- `CLAUDE.md` (root): test first, a pass-or-fail check for every change, reuse before you
  create. The ledger write reuses the lock and the mode of `write_line`. The note reuses
  `scrub`. The report reuses `report_rows` and `nudge_rows` and does not group rows again.
- `tests/no_machine_content.sh`: no machine path in a committed file. The plist exists only
  as a template string, filled at install time (REQ-9.13).
- The `bin/warden-lesson` wrapper runs the script with `python3 -I`. The script folder is
  then not on `sys.path`, so REQ-8.1 loads the ledger module by path.
- The memory note on worktrees: Nicolai's live plugins read from the main checkout, and
  branches live in worktrees. REQ-9.2 keeps the launchd agent off a worktree.

Policy skills: this is a configuration and tooling repository with no domain. REQ-5.5 and
REQ-7.2 are privacy measures from the design, not policy skills.

## Open questions carried from intent

- The merge-day edge: answered by REQ-3 and REQ-3.1.
- The app name for `osascript` notifications: answered in the plan. It is Script Editor.

## Design notes

**Known limits.**
- The session day comes from the first record, not the time the session began. A session that
  began before the pull, and whose first record falls on the next day, counts as an
  after-fix session. This spec documents the limit, and no test covers it.
- A nudge entry cannot see a setup-check miss where no nudge fired.
- The regex `^\(eval\):N: \S+ not found$` also matches any other one-word "not found" line
  from zsh. The `mark` output shows each overlap at seeding.
- launchd runs a missed Monday job at the next wake, but not after a shutdown. `STALE` in
  `status` shows a missed week.
- `weekly/launchd.err` has no size limit. It receives only Python tracebacks.

**Output shapes.** The report section from REQ-4.2 and REQ-4.3:

```
Fixed but recurring:
!!  zsh-equals-word  verified #11 2026-11-10  2 sessions after fix
      s3  x4  Warden_public  echo  (eval):1: foo not found
!!  setup-check-miss  fixed #13 2026-11-25  1 session after fix
      2026-12-01  bed-finder  no setup-call
```

The notification from REQ-5.4:

```
Warden lessons
1 fixed entry recurring, 2 flagged signatures without an entry.
~/.claude/lessons/weekly/report-2026-11-30.txt
```

**Test seams.** The tests set `WARDEN_LESSON_ROOT`, `WARDEN_LAUNCH_AGENTS` and `WARDEN_NOW`,
and a fixed `TZ`. PATH stubs in `tests/stubs/` replace `osascript` and `launchctl`.

**Test list.** T1 to T27 and T18b, as approved in design section 4, with the T12 fix. They
live in `tests/warden_ledger.sh`, which `tests/run.sh` calls.

**Measures after the merge.** These come from the intent. Nicolai reads them, not a test.
- The test notification at `schedule install` and Nicolai's confirmation (REQ-9.7 to
  REQ-9.10) cover the measure "the notification path fires at least once".
- About 2026-12-10, `status` shows two real Monday runs.
- Every notification is a real recurrence or a new flagged signature.
- REQ-9.7 sends the test notification through the launchd agent, so the confirmation covers
  the path that the weekly run uses. A block that macOS adds after the install stays
  invisible, because `osascript` still exits 0.
- macOS lists `osascript` notifications under Script Editor in System Settings >
  Notifications. Sources: forum reports and a Claude Code issue, not Apple documentation.
