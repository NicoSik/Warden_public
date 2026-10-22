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

A baseline of `-` in an arms row means candidate only. The wrapper resolves no baseline, runs and
counts one arm for that row, and the record has no baseline row for it.

Cases whose name starts with `read-order` (including `read-order-heldout`) are graded by
`lib/graph_first.py`. After grading, the run prints the first 5 tool calls of every such run to the
terminal under `first commands: <case> / <arm> / run <i>`. This text never goes into the record.

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
