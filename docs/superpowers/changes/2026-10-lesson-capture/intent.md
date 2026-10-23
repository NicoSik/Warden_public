# Intent: Lesson capture (P1)

Author: Nicolai Sikora. Date: 2026-10-23. Status: approved.

## Problem
Real failures in Nicolai's daily Claude Code sessions leave no record outside the
transcript. Transcripts are deleted after 30 days, and nobody reads them anyway. So there
is no data to decide what triage (P3) should do. Today the only record is memory.

## Proposed outcome
A lesson inbox outside every repository fills itself during normal work. A hook records
clear failures: failed Bash commands, and test failures that later pass. Nicolai or the
agent can add a lesson by hand with `warden-lesson add`, and `warden-lesson list` shows
the inbox. After about two weeks there is real data to design triage from.

## Affected users and systems
- Nicolai only, in every session where the warden plugin is enabled.
- The warden plugin: a new hook. It reaches his sessions without `install.sh`, which he
  does not run.
- A new `warden-lesson` command.
- A new inbox folder outside every repository.
- The behavior harness: the merged eval arm now carries the capture hook too.

## Constraints
- A record holds a short summary and a pointer, never transcript text.
- The pointer is the session ID, the transcript path and the tool call ID. The record
  stays useful after the transcript is deleted.
- Each record carries an error signature: the first stderr line, cut to about 120
  characters, with paths replaced by `<path>`.
- Every stored text field passes the secret scrub.
- The inbox lives outside every repository.
- Each record names its source: `hook`, `user` or `agent`.
- The hook never blocks a tool call and never makes a model call.
- The hook adds under 50 ms per tool call, and a test measures it.
- An environment variable switches the hook off.
- A failed inbox write is silent. It never surfaces an error in Nicolai's session.
- No cleanup setting changes.

## Decisions from the interview (2026-10-23)
- Which failures count: every non-zero Bash exit, except exit 1 from commands where 1
  means "no" (`grep`/`rg`, `test`/`[`, `diff`/`cmp`, `git diff --quiet`, `pgrep`,
  `command -v`/`which`). Exit codes 130 and 143 are skipped.
- One record per error signature per session, with a count for repeats.
- A test-like command that fails and later passes with the same text in the same working
  directory updates its record: `fixed = true`, a pointer to the passing call, and the
  number of file edits in between. A plain rerun shows 0 edits.
- `warden-lesson add "<one line>" [--by agent]` records a scrubbed line of about 200
  characters at most, with the repository, branch, commit and, inside a session, the
  session ID. The source defaults to `user`. `warden-lesson list` prints the inbox newest
  first and shows the source.

## Out of scope
- Triage, grouping and ranking of lessons (P3).
- Automatic proposals or rule edits.
- Linking a fix that a different command verified, such as a narrower test. This is a
  known limit.

## How we will know it worked
- Offline tests with synthetic hook payloads:
  - a secret planted in stderr, and one planted in `add` text, never reaches the inbox;
  - the exclusions, exit codes 130 and 143, the dedupe counts and the fix linking behave
    as specified;
  - every field stays within its cap;
  - the hook stays under 50 ms per call;
  - the off switch and a failed inbox write leave no output and no error.
- In an eval run, the capture hook writes only inside the eval's temporary `HOME`, never
  to Nicolai's real inbox.
- After about two weeks of daily use, the inbox holds records from real sessions, a
  secret-shape scan over it finds nothing, and Nicolai can say what triage needs.

## Open questions
- Which fields the PostToolUse payload gives for a failed Bash call (exit code, stderr),
  and whether a separate failure event exists. Research this in the spec.
- How the hook recognises a "test-like" command.
- The inbox path and format, a size cap, and safe writes when parallel sessions append at
  the same time.
- Whether `claude plugin eval` sets `HOME` to its temporary folder for every run.
