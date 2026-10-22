<p align="center">
  <img src="assets/warden.png" alt="A knight in full plate armour and a great helm, drawn in black and bone white against a red ground, with red eyes behind the visor." width="640">
</p>

# Warden

A complete Claude Code setup in one folder. Clone it, run one command, and a new computer
behaves like the old one.

## Install

```bash
git clone https://github.com/BlastBlastBlast/Warden_public.git
cd Warden_public
./install.sh --dry-run    # see what it would do
./install.sh              # do it
```

The installer supports macOS and Linux. Windows is not supported: the hooks and the tools are
bash scripts.

Claude can run the install for you. Open Claude Code in the clone and say "install this".
Claude reads `INSTALL.md`, tells you every path it will write to, and waits for your consent.

## What the installer does to your computer

| Path | What happens |
|---|---|
| `$HOME/.warden-backups/claude-<stamp>.tar.gz` | Your Claude configuration directory, archived before the first change. Leaves out `projects/`, `sessions/`, and the other caches — never captured, never restored. |
| `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` | Nine symbolic links into this repository. Anything displaced is renamed, never removed. |
| `$HOME/.local/bin/warden-handoff` | A link to the handoff tool. |
| `$HOME/bin` | The two context-monitor binaries, checksum-verified. |
| `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json` | Three plugin marketplaces registered through the `claude` CLI: the `superpowers` and `warden` plugins vendored in this repository, and `cathrynlavery/diagram-design`, which the CLI clones from GitHub. The CLI writes that file, not the installer. |
| this clone's `.git/config` | `core.hooksPath` set to `.githooks`, so the pre-commit scrub hook runs. This clone only, never a global git setting, and skipped when `core.hooksPath` already points somewhere else. |

The installer needs network access: the `claude` CLI clones the diagram-design marketplace, and
the context-monitor release comes from GitHub. `./install.sh --skip-deps` does neither, and needs
no network.

## Reverting

```bash
./uninstall.sh                      # remove the links, put back what they displaced
./uninstall.sh --from-archive       # list the archives
./uninstall.sh --from-archive <path>   # restore the configuration from one
```

A restore returns your configuration. It leaves `projects/`, `sessions/` and the other caches
alone, because the archive never held them.

## Layout

| Path | Links to | Holds |
|---|---|---|
| `CLAUDE.md` | the config directory | Always-on instructions, 72 lines (limit 200) |
| `settings.json` | the config directory | Attribution, permissions, wired hooks, subagent model and caps, Opus 5.5 effort |
| `hooks/` | the config directory | Two secret guards and the default-branch guard, all wired |
| `output-styles/` | the config directory | `plain-technical`, the writing discipline |
| `rules/` | the config directory | `instruction-files.md`, path-scoped |
| `skills/` | the config directory | Skills the superpowers plugin does not cover |
| `docs/references/` | the config directory | Reference files the rules load |
| `docs/decisions/` | the config directory | Why this setup is shaped the way it is |
| `bin/` | the config directory | `warden-handoff`, `warden-statusline`, `warden-session-tokens`, `warden-usage` |
| `plugins/superpowers/` | not linked | The vendored method plugin |
| `plugins/warden/` | not linked | The plugin that injects the Code Map rule at session start and into each subagent |

## Wired hooks

| Hook | Event | Blocks |
|---|---|---|
| `guard-secrets.sh` | PreToolUse Write, Edit | A write carrying a private-key header, an AWS key id, or a 32-character bearer token. Skips fixtures and `*.example`. |
| `guard-secrets-read.sh` | PreToolUse Bash | A shell command that puts a secret file in front of the model. Excludes `ls`, `wc`, `cp`, and `.env.example`. |
| `claude-context-monitor` | PostToolUse | Nothing. It warns at 35 percent context remaining and goes critical at 25 percent. |
| `warden-handoff hook` | SessionStart | Nothing. It offers a waiting handoff after `/clear`, once. |
| `guard-default-branch.sh` | PreToolUse Write, Edit, NotebookEdit | An edit to a file whose repository is on its default branch. It prints the `git switch -c` command. |

Test the branch guard with `bash hooks/tests/guard-default-branch.test.sh`.

## Skills

| Skill | Fires when |
|---|---|
| `crit` | You review code, a plan, or a page with inline comments. |
| `crit-cli` | An agent authors or replies to crit comments. |
| `design-taste-frontend` | You build a landing page, a marketing site, or a portfolio. |
| `eli5` | You ask for a dead-simple picture explainer. |
| `emil-design-eng` | You build product UI: dashboards, tables, forms, wizards. |
| `handoff` | You end a session and want to continue in a fresh one. |
| `review-animations` | You review motion and transitions. |
| `source-authority` | You are about to state a version, a flag, or a default from memory. |

## Status line

Three lines:

```
Opus 5.5 │ Warden ⎇ main
5h 7% · 4h24m   7d 41% · 2d5h
opus-5.5 out 236  new 21k  cached 34k
```

Line one is `claude-statusline` from `stigsb/claude-context-monitor`. Line two is ours: plan
usage from the `rate_limits` payload, dim under 50 percent, yellow from 50, red from 80. Line
two is absent when Claude Code sends no rate limit.

Line three is also ours, from `warden-session-tokens --line`. It counts the tokens of the current
session per model, subagents included: `out` is output tokens, `new` is input plus cache write,
and `cached` is cache read. Line three is dim. It is absent when there is nothing to report, and a
failure in the helper never removes lines one or two.

### Usage across sessions

`warden-usage` runs a pinned [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage) through
`npx` for reports across all sessions on this machine:

- `warden-usage` gives a daily report.
- `warden-usage week` gives a weekly report.
- `warden-usage month` gives a monthly report.
- `warden-usage session` gives a report per session.

The installer does not put `warden-usage` on your `PATH`. To run it from anywhere, link it:

```
ln -s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bin/warden-usage" ~/.local/bin/warden-usage
```

Test the three scripts with `bash bin/tests/warden-statusline.test.sh`,
`bash bin/tests/warden-session-tokens.test.sh` and `bash bin/tests/warden-usage.test.sh`.

## Tools this setup draws on

| Tool | What it does | Installed |
|---|---|---|
| [obra/superpowers](https://github.com/obra/superpowers) | Gives an agent skills that fire on their own, for planning, test-first work and debugging. | Yes, as a vendored fork |
| [cathrynlavery/diagram-design](https://github.com/cathrynlavery/diagram-design) | Draws a figure to a named visual type, and holds the drawing to that type's rules. | Yes |
| [stigsb/claude-context-monitor](https://github.com/stigsb/claude-context-monitor) | Shows how much context window remains, to the person and to the agent. | Yes |
| [github/spec-kit](https://github.com/github/spec-kit) | Starts a change from a written specification, then builds the code to match it. | No |
| [danyuchn/asd-ste100-skill](https://github.com/danyuchn/asd-ste100-skill) | Rewrites English to ASD-STE100, and lints a document against the standard. | No |
| [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) | Turns a codebase and its documents into a knowledge graph an agent can query. | No |
| [stablyai/orca](https://github.com/stablyai/orca) | Runs several coding agents at once, each one in its own worktree. | No |
| [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) | Holds several agent sessions in one macOS terminal, with vertical tabs and notifications. | No |
| [firecrawl/pdf-inspector](https://github.com/firecrawl/pdf-inspector) | Tells a scanned PDF from a text PDF, then extracts the text as Markdown. | No |
| [anthropics/claude-plugins-community](https://github.com/anthropics/claude-plugins-community) | A community marketplace of Claude Code plugins. | No |

## Licence

The files in this repository are MIT. `plugins/superpowers/` is a vendored copy of
`obra/superpowers` by Jesse Vincent, also MIT. See `plugins/superpowers/NOTICE.md`.
