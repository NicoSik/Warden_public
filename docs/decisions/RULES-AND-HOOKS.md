# Rules and hooks — names, functions, and what is wired

## Hooks

Blocking behaviour is the column that matters. `deny` stops the tool call. `ask` turns it into a
prompt. `report` writes text back and changes nothing.

| Hook | Event | Function | Blocks? | Status |
|---|---|---|---|---|
| `guard-secrets.sh` | PreToolUse Write\|Edit | Denies a write carrying one of three high-confidence secret shapes: a `BEGIN PRIVATE KEY` header, an `AKIA`/`ASIA` AWS key id, or a bearer token of 32+ chars. Skips `fixtures/`, `testdata/`, `*.example`, `*.sample`. Names the shape, never the value. | **deny** | **KEPT, wired** |
| `guard-secrets-read.sh` | PreToolUse Bash | Denies a shell command that puts a secret file's contents in front of the model. Exists because `permissions.deny` on Read is not extended to every Bash command — measured 2026-09-14 against 2.1.270, `cat .env` is blocked but `head -1 .env` returns the secret. Excludes `ls`/`stat`/`wc` (metadata), `cp`/`mv` (moving is not reading), and `.env.example` and friends. | **deny** | **KEPT, wired** |
| `guard-default-branch.sh` | PreToolUse Write\|Edit\|NotebookEdit | Denies a file edit while HEAD is the repo's default branch, and prints the `git switch -c` command. | **deny** | **wired 2026-09-23** with the Opus 5.5 keep-going rule. Judges the edited file's repository. See note below. |
| `guard-test-files.sh` | PreToolUse Write\|Edit | Prompts before editing a test that already exists. A new test never prompts. An edit whose `old_string` survives inside `new_string` is growth, not weakening, and passes. | ask | scrapped, not imported |
| `guard-stage-order.sh` | PreToolUse Write\|Edit | Denies writing a stage artifact before the previous stage finished — no `spec.md` without `intent.md`. | deny | scrapped, not imported |
| `guard-protected-paths.sh` | PreToolUse Write\|Edit | Denies edits to paths a project declares in `.claude/guardrails.json`. No-ops when undeclared. | deny | scrapped, not imported |
| `claude-guard-destructive` | PreToolUse Bash | Blocks `curl`/`wget` piped into a shell, in its common forms, which a static glob cannot match. | deny | scrapped, not imported |
| `claude-guard-agent-dispatch` | PreToolUse Agent | Requires a generic subagent dispatch to name a `model`, so mechanical work does not run on the session's expensive model. | deny | scrapped, not imported |
| `plan-drift.sh` | Stop | Reports when the working tree touches files `plan.md` does not name. Guards its own re-entry so the report does not repeat on every Stop. | report | scrapped, not imported |
| `config-drift.sh` | Stop | Reports when live `settings.json` drifts from its committed state, because Claude Code rewrites that file at runtime and a long session can revert it. | report | scrapped, not imported |
| `ste-lint-spec.sh` | PostToolUse Write\|Edit | Lints spec and plan documents against the spec-language rules. Advisory. | report | scrapped, not imported |
| `setup-nudge` | PostToolUse Bash\|Skill | Reminds the main agent once to run the setup check for a new repository. The repository needs 20 or more source files first. Silent for repositories older than the session. | report | **wired 2026-11** |

Wired now: **two secret guards, the default-branch guard, and the setup-check nudge.** Everything else is out.

Two of the scrapped ones never blocked anything — `plan-drift.sh` and `config-drift.sh` only write
text back. They are out anyway because both belong to the chain, and `config-drift.sh` assumes
`~/.claude/settings.json` is a symlink into a repo.

### Note on the default-branch guard

**Resolved 2026-09-23:** wired, because the new keep-going rule in `CLAUDE.md` means fewer stops
(`OPUS-5-5-EVALUATION.md`, E9 and E23). The text below is the earlier decision record.

Scrapping it drops enforcement of your own rule 2, "never work directly in main, branch first".
The rule still exists as prose in `CLAUDE.md`, which is a request rather than a guarantee. Three ways
to go, your call:

1. **Leave it scrapped.** The prose rule carries it.
2. **Rewire as-is.** It denies the first edit and prints the branch command. One block per branch,
   then silence.
3. **Make it report instead of deny.** Exit 0 with `additionalContext` telling Claude to branch.
   Never blocks, and Claude nearly always acts on it.

## Rules

Rules never block. They are context. The cost is that an unscoped rule loads in every session.

| Rule | Scope | Function | Verdict |
|---|---|---|---|
| `instruction-files.md` | `CLAUDE.md`, `AGENTS.md`, `SKILL.md`, rules, settings | Which tier to put guidance in — the same conclusion `ARCHITECTURE.md` reached, already written and already path-scoped. | **Keep. Supersedes our `skill-authoring.md`.** |
| `tests.md` | test-file globs | How to write a test: what to assert, what not to mock, when a test is weakened. | **Keep.** Free unless you are in a test file. |
| `spec-language.md` | spec/plan/ADR paths | One normative keyword per requirement, one reading per sentence. | Keep if you keep the chain. |
| `change-records.md` | `docs/changes/**` | The `docs/changes/<YYYY-MM>-<slug>/` layout and what each artifact holds. | Keep if you keep the chain. |
| `model-selection.md` | **always on** | Opus plans and reviews, Sonnet executes a fully specified task, Opus takes over when something is unknown. | **Keep.** 28 lines, and it is the cost control. |
| `response-style.md` | **always on** | How to talk to you: answer last or first but never both, say each fact once, match detail to task size, reference codes when listing 3+ items. | Overlaps our output style. See below. |
| `research.md` (ours) | **always on** | Source tiers, when to research instead of recall, citation format. | **Keep.** Nothing else covers it. |
| `skill-authoring.md` (ours) | `**/SKILL.md` | How to write a skill. | **Drop.** `instruction-files.md` covers it and more. |

Always-on rules after this: `model-selection.md`, `research.md`, and whatever wins the style slot —
roughly 120 lines on top of `CLAUDE.md`.

### The style overlap

`response-style.md` (rule, 52 lines) and `output-styles/plain-technical.md` (output style, 52 lines)
both load every turn and both say how to write. The rule has one thing the output style lacks:
**reference codes for lists of three or more**, which is why this document numbers nothing and the
tables above name every row. Folding that into the output style leaves one surface instead of two.
