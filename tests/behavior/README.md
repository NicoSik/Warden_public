# Behavior baseline

A rerunnable behavior test for the vendored Superpowers plugin (`plugins/superpowers`). It runs
`claude plugin eval` against two commits per case and writes a record.

## Run it

```
tests/behavior/run-behavior [--case <name>|all] [--runs N] [--model ID] [--yes]
```

- `--case` picks one case from `evals/arms.conf`. The default is `all`.
- `--runs` sets runs per case and arm. The default is 5. The success counts in `arms.conf` assume 5.
- `--model` pins a model. Without it the run uses your account default.
- `--yes` skips the confirmation. Only the offline test uses it.

Each arm comes from `git archive <ref> plugins/superpowers` into a scratch directory. The run never
checks out a ref and never touches your project, your `~/.claude`, or the git state of this repo.
Log in with a subscription. `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` must be unset.

The record goes to `docs/superpowers/changes/2026-10-rerunnable-behavior-baseline/runs/<UTC date>-<id>.md`.
Raw result JSON is kept outside the repo in `~/.cache/warden-behavior/<id>/`.

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
