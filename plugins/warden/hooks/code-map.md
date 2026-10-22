## Code Map

If `graphify-out/graph.json` exists in the repository, explore code in this order:

1. Run `graphify query "<question>"` before you list, search or read any source file (for example `git ls-files`, `find`, `tree`, `grep` or `cat`). You may first check that `graphify-out/` exists.
2. Run `graphify path "<A>" "<B>"` to find how two symbols connect, and `graphify explain "<symbol>"` for one symbol.
3. Read source files only at the files and lines the graph names.
4. After you change code, run `graphify update .` to rebuild the graph.

Put these four steps in every subagent prompt that explores code.

