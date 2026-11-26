# Intent: Lessons ledger and weekly report

Author: Nicolai Sikora. Date: 2026-11-26. Status: approved.

## Problem
`warden-lesson report` shows repeated failures, but it does not know which ones were already
fixed. After a fix PR merges, a recurrence looks the same as a new failure. A known
non-failure stays flagged every week: the Hedges row is a script's output line, and it is
flagged today. Nicolai reads the report only when he remembers to, so a fix that did not
hold can go unseen for weeks. The fixes from #11 (zsh `=word` and `--include=`) and #13
(setup-check nudge) have no record that says "watch for these".

## Proposed outcome
A ledger next to the inbox records a decision per failure class. Each entry has a slug, a
regex over the normalized signature (anchored where possible), a status, a note and a date.
The statuses are open, fixed (with the PR), verified, and ignored (with a reason).
`warden-lesson mark` creates and updates entries. It takes the PR merge date as
`--fixed-on`. It prints which existing records the regex matches and how many, so an
over-broad regex is visible at once.

`ledger.jsonl` is append-only. The latest line per slug wins, so the history of every
decision stays in the file and an undo is one more `mark`.

The report shows "fixed but recurring" first: a fixed or verified entry with a match after
its fix date. Each report row shows its ledger status. Ignored entries are hidden and
counted with the other hidden rows.

A launchd job runs the report every Monday at about 09:15. It writes the full report to a
file. It shows a macOS notification (osascript) that names the report file, only when:
- a fixed or verified entry gets a new match after its fix date (this always notifies), or
- a flagged signature has no ledger entry.

`warden-lesson status` shows the time of the last weekly run, so silence cannot hide a broken
job. `warden-lesson schedule install` and `warden-lesson schedule uninstall` add and remove
the launchd agent.

Seed entries:
- `zsh-equals-word`: zsh `=word`. Fixed by #11 on 2026-11-10, verified.
- `zsh-include-glob`: zsh `--include=` glob. Fixed by #11 on 2026-11-10, verified. Evidence:
  0 occurrences in the 9 sessions from 2026-11-10 to 2026-11-17, the week after #11.
- `setup-check-miss`: fixed by #13 on 2026-11-25, live check pending. It matches a nudge with
  no setup-call, not a signature. Its note says it cannot see misses where no nudge fired.
- `hedges-output-line`: ignored. Reason: a script's output line, not a failure. This is the
  first real use of `mark`.

## Affected users and systems
- Nicolai, as the only reader of the report and the notification.
- `plugins/warden/scripts/warden-lesson` and `tests/warden_lessons.sh`.
- The new `~/.claude/lessons/ledger.jsonl`. The inbox format does not change.
- A launchd agent in `~/Library/LaunchAgents`, written by `schedule install`.

## Constraints
- Only `mark` writes `ledger.jsonl`, and only by appending a line.
- Retention never deletes or changes `ledger.jsonl`. A test proves this.
- The append-only history is the backup. There is no separate backup.
- The report and the weekly run never write to the ledger or to the inbox.
- The capture hook stays fast and never fails a tool call.
- The plist is generated from a template at install time. Nothing with a home path is
  committed.
- Existing `report`, `list`, `status`, `add`, `hook` and `nudge` output stays the same,
  except for the added ledger status and the last-run line.

## Out of scope
- Email, Slack or any message that leaves the Mac.
- Cloud routines or a Claude session cron.
- Automatic status changes, for example open to verified after N quiet weeks.
- Committing the ledger to the repo.
- Running `install.sh` on this Mac.

## How we will know it worked
- Offline tests with a synthetic inbox and ledger check that:
  - a fixed entry with a match after its fix date is listed first and triggers a
    notification,
  - an ignored entry is hidden and counted,
  - an unacknowledged flagged signature triggers a notification,
  - a quiet week writes the report file and shows no notification,
  - retention leaves `ledger.jsonl` untouched,
  - `mark` prints the match count,
  - the latest line per slug wins, and an earlier status comes back with one more `mark`.
- After the seeding, `report` shows the Hedges row as ignored. `mark` prints 1 match for
  `zsh-equals-word` and 0 for `zsh-include-glob`.
- Before 2026-12-10:
  - `status` shows the time of a real Monday run.
  - The notification path has fired at least once.
  - Every notification was a real recurrence or a new flagged signature.

## Resolved questions
- Entries are named by slug.
- The fix date is the PR merge date, given as `--fixed-on`.
- `warden-lesson schedule install` and `uninstall` manage the launchd agent. `install.sh` is
  not involved.
- The job runs on Monday at about 09:15.
- The notification uses osascript and names the report file. It does not open the file.
- The ledger is append-only, and the latest line per slug wins. There is no separate backup.

## Open questions
- The merge-day edge. A session that started before the pull can still run the old code on
  the merge day, and its failure counts as a match after the fix date. The spec has to decide
  whether "after" means after the merge day, or after the merge time with that edge accepted.
