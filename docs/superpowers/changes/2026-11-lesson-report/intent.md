# Intent: Lesson report

Author: Nicolai Sikora. Date: 2026-11-17. Status: approved.

## Problem
The lesson inbox holds 22 clean records after one week. `warden-lesson list` shows each
record per session, so a failure that repeats across sessions or repos is not visible as a
repeat. Most rows are ordinary debugging, so the few rows that matter are hard to find.
Node failures get the signature `node:internal<path>:N` instead of the `Error:` line, so two
different Node errors look the same and the real cause is lost.

## Proposed outcome
`warden-lesson report` groups the failures by normalized signature across all sessions and
repos. A signature seen in 2 or more repos, or in 3 or more sessions, is flagged. Fixed test
failures and one-off exceptions from a project's own code are hidden. A test failure that
passed again with 0 edits in between is flaky: it stays visible and is marked flaky. Rows
with an empty signature are hidden. The default output ends with a count of the hidden rows
per reason. `report --all` also shows the hidden rows. A hidden signature that appears again
in another session or repo is no longer hidden. Manual lessons appear in a short section of
their own, ungrouped. Node failures get the `Error:` line as their signature.

## Affected users and systems
- Nicolai, as the only reader of the report.
- `plugins/warden/scripts/warden-lesson` and its tests in `tests/warden_lessons.sh`.
- The inbox at `~/.claude/lessons` is read only. Its format does not change.

## Constraints
- The report is read-only. It writes nothing and proposes nothing.
- The capture hook stays fast and never fails a tool call.
- Existing `list`, `status`, `add` and `hook` behaviour stays the same,
  except for the Node signature fix.
- A fixed test failure is a test failure that passed again with more than 0 edits in between.
- A one-off exception is an exception signature seen once, in one session.
  Environment classes stay visible: `ModuleNotFoundError`, `ImportError`, `FileNotFoundError`,
  `PermissionError`, `ConnectionRefusedError`, `TimeoutError`, `OSError`, and `command not found`.

## Out of scope
- Proposals, rule drafts or any automatic action from the report.
- Recording traceback frames at capture time (option B). This stays a later option
  if code exceptions clutter the report.
- Rewriting signatures of records already in the inbox.
- The bed-finder setup-check gap. That gets its own intent after this one.

## How we will know it worked
- An offline test builds a synthetic inbox with: 2 repos, 3 sessions in one repo, an x3
  retry in one session (not flagged), a one-off `KeyError` that reappears in a second
  session (shown), a fixed test failure, a flaky test failure, an empty signature and a
  manual lesson. The test asserts the flagged, shown and hidden rows and the hidden count
  per reason.
- After the next week of data, `report` shows every repeated signature on one line, and
  the hidden-row counts account for the rest.
- New Node failures in the inbox carry an `Error:` signature, not `node:internal`.

## Resolved questions
- "3 or more times" counts sessions, not raw occurrences.
- Rows with an empty signature are hidden under the reason "no signature".
- Manual lessons are listed in their own section, ungrouped.
