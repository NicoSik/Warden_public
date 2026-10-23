**Setup check.** Before the first code exploration in brainstorming, writing-plans, writing-specs or systematic-debugging, run this command once per repository per session. `$SETUP` below stands for the same quoted path.

```bash
"{{GRAPHIFY_SETUP}}" status
```

Act on the word it prints:

- `ask`: in its own message, ask your human partner "Build a code graph for this repo with Graphify? It adds `graphify-out/` to `.gitignore` and, where git allows it, hooks that keep the graph current." If yes, run `"$SETUP" setup` and tell them what it printed. If no, run `"$SETUP" decline`. If they do not answer, run neither.
- `build`: your human partner already said yes for this repository. Run `"$SETUP" setup` without asking, and mention the result in one line.
- `no-cli`: run `"$SETUP" notice`, and pass on any line it prints.
- `unavailable`: pass on the line the script printed, once, and continue without Graphify.
- `ready`, `declined`, `small`, or anything else: say nothing about Graphify and continue.
