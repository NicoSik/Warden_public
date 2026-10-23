# Intent: Graphify setup on first use

Author: Nicolai Sikora. Date: 2026-10-20. Status: approved.

## Problem
The Superpowers "Code Map" rule only does something in a repo that already has
graphify-out/graph.json. Today that graph exists only if Nicolai remembers to run
`graphify update .` and `graphify hook install` by hand in each project. In every
other repo, agents fall back to grep and whole-file reads, even on a machine that
has Graphify installed.

## Proposed outcome
When Nicolai starts real work in a repo with no graph, the agent asks once:
"Build a code graph for this repo?" A yes builds the graph, installs the git hooks
that keep it fresh, and adds graphify-out/ to .gitignore. From then on the Code Map
rule applies in that repo with no manual steps. A no is remembered, and the agent
does not ask again in that repo. On a machine without Graphify, the agent says once
that it would help and how to install it, then carries on as today.

## Affected users and systems
- Nicolai, in every repo he works in with the superpowers-dev plugin.
- The Superpowers fork (NicoSik/Warden_public): the skills that explore code,
  which are brainstorming, writing-plans, writing-specs and systematic-debugging.
- Each target repo: graphify-out/, .gitignore, and .git/hooks.
- Teammates who use the fork: they see the .gitignore line. Without Graphify,
  they get no question and no change.

## Constraints
- No question during quick questions or chat. It comes only when one of the four
  skills is about to explore code.
- At most one question per repo, and a "no" is final for that repo.
- No software is installed on the machine without Nicolai doing it himself.
- The skills keep working exactly as today when Graphify is missing or declined.
- Building the graph makes no model calls (code only).

## Out of scope
- Making graph use mandatory through blocking hooks.
- Deeper graph use inside the skills, such as `affected` before a refactor or
  `path` during debugging.
- Semantic extraction of docs, PDFs and images.
- Committing the graph so teammates share it.

## How we will know it worked
After about two weeks of normal use: every repo where Nicolai said yes has a fresh
graph, he never ran a graphify command by hand, and no repo asked twice.

## Open questions
- Should tiny repos be skipped without a question? Proposed default: skip below
  about 20 source files.
- Where is the "no" remembered? It needs a per-repo record that is not committed.
- Where is "already mentioned the install" remembered? It needs a per-machine record.
- Does a .gitignore change on a branch Nicolai did not plan to touch get its own
  commit, or does it wait for him?
- How do we test the trigger? The earlier micro-test checked reads, not a
  one-time question.
