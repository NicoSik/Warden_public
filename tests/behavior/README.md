# Behavior baseline

A rerunnable behavior test for the vendored Superpowers plugin (`plugins/superpowers`). It runs
`claude plugin eval` against two commits per case and writes a record.

## Run it

```
tests/behavior/run-behavior [--case <name>|all] [--runs N] [--model ID] [--arms FILE] [--record-dir DIR] [--yes]
```

- `--case` picks one case from `evals/arms.conf`. The default is `all`.
- `--runs` sets runs per case and arm. The default is 5. The success counts in `arms.conf` assume 5.
- `--model` pins a model. Without it the run uses your account default.
- `--arms` sets the arms file. The default is `evals/arms.conf`. A missing file exits 2 with
  `arms file not found: FILE`.
- `--record-dir` sets the record folder. The precedence is the flag, then
  `WARDEN_BEHAVIOR_RECORD_DIR`, then the default folder below.
- `--yes` skips the confirmation. Only the offline test uses it.

An arms row is `<case> <base> <cand> <rule> <count> [<model>]`. The optional sixth column pins the model of the
candidate arm (it passes `--model <model>` for that arm). An arm key is `<sha>` without a model and
`<sha>@<model>` with one, so two arms can share one commit. Their traces go to `<sha7>` and `<sha7>-<model>`.
The Results table gets a `model` column after `SHA` only when two arms on one commit differ in model.

A baseline of `-` in an arms row means candidate only. The wrapper resolves no baseline, runs and
counts one arm for that row, and the record has no baseline row for it.

Cases whose name starts with `read-order` (including `read-order-heldout`) are graded by
`lib/graph_first.py`. After grading, the run prints the first 5 tool calls of every such run to the
terminal under `first commands: <case> / <arm> / run <i>`. This text never goes into the record.

In the `read-order` and `read-order-heldout` cases, the wrapper runs each arm on its own copy. In that copy, `lib/setup-status-stub` takes the place of `scripts/graphify-setup`. The stub prints `ready` for `status` and refuses every other subcommand. The eval sandbox blocks git, so the real script always prints `unavailable` there, and `setup-check.md` then tells the agent to continue without Graphify. A real session in a repository with a graph prints `ready`. An arm without `graphify-setup` runs unchanged. The record pins `Setup status of <sha> in <case>: stubbed (ready)` or `not present`. The setup cases always use the real script.

Each arm comes from `git archive <ref> plugins/superpowers` into a scratch directory. The run never
checks out a ref and never touches your project, your `~/.claude`, or the git state of this repo.
`claude plugin eval` loads one plugin. When an arm has `plugins/warden`, the wrapper archives the whole
plugin and merges it into the scratch Superpowers plugin. The merge copies every file of `plugins/warden`
except its manifest (`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`) to the same relative
path in the scratch plugin, and appends each `warden` hook entry to the matching event array of the scratch
`hooks/hooks.json`. Any other file in `plugins/warden/.claude-plugin/` makes the wrapper exit 2 with
`unexpected warden manifest file: .claude-plugin/<name>`. If a copied file already exists, the wrapper exits 2
with `merge collision: <path>`. After the merge, `lib/merge_check.py` checks that every copied file is in the
scratch plugin, byte-equal. If not, the wrapper exits 2 with `merge incomplete: <path>`. Each of these stops
the run before any eval. An arm without `plugins/warden` builds the same scratch tree as before. Limit: the
proof covers the merged plugin, not the real install of two plugins side by side. In the merged arm a `warden`
skill loads as `superpowers:<name>`. The setup grader counts Bash calls to `graphify-setup ... status`, so the
name does not change its count. PR #2's smoke check covers the real `warden:<name>` load.

Test-only override: `WARDEN_BEHAVIOR_MERGE_CHECK` replaces `lib/merge_check.py` with another command. The
wrapper prints a warning, the record pins `- Merge check: STUB`, every result reads `STUB`, and the exit is 1,
so a run with the override can never read as a pass. Never set it for a real run.

Log in with a subscription. `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` must be unset.

The record goes to `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<UTC date>-<id>.md`.
Raw result JSON is kept outside the repo in `~/.cache/warden-behavior/<id>/`.

The trace cache is `~/.cache/warden-behavior/`. Set `WARDEN_BEHAVIOR_RAW_DIR` to move it. Before the cost
prompt the wrapper checks the nearest existing folder of the trace cache. If that folder is inside a git
work tree, the wrapper exits 2 and names `WARDEN_BEHAVIOR_RAW_DIR`. `record.py` deletes the eval temp
folders, so before it runs the wrapper copies every trace that the results name to
`<id>/traces/<case>/<arm-sha7>/run-<i>.jsonl`. After the record is written, the wrapper deletes the oldest
run folders (by modification time) until 20 remain. It touches only entries whose name is six lowercase
hexadecimal characters.

## Suite mode

`run-behavior --suite [--case NAME] [--runs N] [--ab-model ID] [--record-dir DIR] [--yes]` runs the
criteria of `evals/suite.conf` (one line per case: `<case> <rule> <count>`; `#` starts a comment) against
the HEAD commit of this repository. Before the preflight it checks, in order, and each failure exits 2:

1. The branch is `main`: `suite runs only on main (current: <branch>)`.
2. `git status --porcelain -- plugins tests/behavior` is empty: `suite needs a clean checkout: <path>`.
3. Every eval directory except `_fixture` has a `suite.conf` line (`no suite criterion for <case>`), and every
   line has a directory (`no eval directory for <case>`).

It then prints `warning: main is <N> commits behind fork/main (last fetch)` when `refs/remotes/fork/main` is
ahead of `main`. It never fetches. A missing `fork/main` prints no warning.

The wrapper writes its own arms file into its scratch folder: one candidate-only row per case at HEAD. With
`--ab-model ID` it adds a second row per case with `ID` in the sixth column. The estimate counts distinct case
names, so `--ab-model` over 5 cases prints `Agents: 50 (5 cases, 10 arms x 5 runs)`. The default record folder is
`$WARDEN_LESSON_ROOT/suite` (or `~/.claude/lessons/suite`); `--record-dir` and `WARDEN_BEHAVIOR_RECORD_DIR`
keep their precedence. Suite mode never deletes a file in the record folder.

The recorder runs with `--summary`. After the Markdown record it writes `<UTC date>-<id>.json` beside it
(through a `.tmp` file and `os.replace`): one object with `schema`, `id`, `date`, `sha`, `cli_version`,
`cli_version_raw`, `model`, `graphify_version`, `fixture_hash`, `runs` and `cases`. Each case entry holds
`case`, `arm` (`main`, or `ab` when a model column was given), `model`, `count`, `errored`, `runs`, `rule`,
`threshold` and `result` (`PASS`, `FAIL`, or `ERRORED` when any run errored). No summary is written without
`--summary`, or when the recorder exits 2 before the Markdown write.

## Cost

Before it starts, the wrapper prints the agent count, the model and an estimate, labelled
`list-price estimate; not billed on a subscription login, uses your plan's usage limits`.
It then asks `Start N agents? [y/N]`. The figure is list price. A subscription login is not billed
per run, but the runs use your plan's usage limits. The record repeats the label beside the cost.

## What "attempts" means

Runs measure attempts. Inside the eval sandbox on macOS, git, the home-installed Graphify binary,
and `.git/config` writes are blocked, so `graphify-setup` and `graphify query` fail inside a run.
A run counts as triggered when the agent tries the call, not when the call succeeds.

## Exit codes

- 0: every candidate criterion is met.
- 1: a candidate criterion failed.
- 2: usage error, declined prompt, or a partial or unreadable eval result.
- 3: preflight failed (`claude` or `graphify` missing, an API key variable set, or an unresolved ref).

## Tests

`bash tests/behavior_harness.sh runner` runs the offline tests with stub `claude` and `graphify`.
`tests/run.sh` does not run this directory and never starts a live agent.
