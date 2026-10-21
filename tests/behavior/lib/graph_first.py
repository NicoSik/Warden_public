"""Report whether a graph query came before the first exploration call in a trace."""
import json
import re
import shlex
import sys

EXPLORE_TOOLS = ("Read", "Grep", "Glob")
EXPLORE_CMD = re.compile(
    r"^\s*(grep|rg|find|cat|sed|head|ls|tail|tree|wc|git\s+grep|git\s+ls-files)\b"
)
CD_CMD = re.compile(r"^\s*cd(\s+(\S+))?\s*$")
SPLIT = re.compile(r"(&&|\|\||;|\|)")
OUT = "graphify-out"
GRAPH_CMD = re.compile(r"graphify\s+(query|explain|path)\b")


def tool_calls(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            msg = obj.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    inp = block.get("input")
                    yield block.get("name"), inp if isinstance(inp, dict) else {}


def names_out(token):
    """True when token is graphify-out or a path below it, with no .. part."""
    if ".." in token.split("/"):
        return False
    return token in (OUT, "./" + OUT) or token.startswith((OUT + "/", "./" + OUT + "/"))


def is_path_token(token):
    return "/" in token or token in (OUT, "./" + OUT)


def operands_bare(verb, args):
    """Bare words (no slash) that are certainly paths: find roots, grep files, ls and cat operands."""
    plain = [t for t in args if not t.startswith("-")]
    if verb in ("ls", "tree", "cat", "wc", "git ls-files"):
        return plain
    if verb in ("head", "tail"):
        return [t for t in plain if not t.isdigit()]
    if verb == "sed":
        return plain[1:]  # the first operand is the script
    if verb in ("grep", "rg", "git grep"):
        return plain[1:]  # the first operand is the pattern
    if verb == "find":
        roots = []
        for t in args:
            if t.startswith(("-", "(", "!")):
                break
            roots.append(t)
        return roots
    return []


def is_out_check(verb, rest, in_out):
    """True when an explore segment touches only graphify-out."""
    try:
        args = shlex.split(rest)
    except ValueError:
        args = rest.split()
    if in_out:
        args = [t for t in args if not t.startswith("-")]
        return all(".." not in t.split("/") for t in args)
    bare = operands_bare(verb, args)
    paths = [t for t in args if is_path_token(t) or t in bare]
    return bool(paths) and all(names_out(t) for t in paths)


def bash_first(cmd):
    """Return 'graph', 'explore' or None for the first segment that is either."""
    parts = SPLIT.split(cmd)
    in_out = False  # set by cd graphify-out, for the rest of the command
    # parts alternate: segment, separator, segment, ...
    for i in range(0, len(parts), 2):
        if i >= 2 and parts[i - 1] == "|":
            continue  # a pipe stage reads stdin; the first command decides
        seg = parts[i].strip().lstrip("(").strip()
        if GRAPH_CMD.search(seg):
            return "graph"
        cd = CD_CMD.match(seg)
        if cd:
            in_out = bool(cd.group(2)) and names_out(cd.group(2))
            continue
        m = EXPLORE_CMD.match(seg)
        if not m:
            continue
        if is_out_check(" ".join(m.group(1).split()), seg[m.end():], in_out):
            continue
        return "explore"
    return None


def classify(name, inp):
    """Return ('graph'|'explore'|None, detail)."""
    if name == "Bash":
        cmd = str(inp.get("command", ""))
        return bash_first(cmd), cmd
    if name in EXPLORE_TOOLS:
        fp, path, pat = (str(inp.get(k) or "") for k in ("file_path", "path", "pattern"))
        if name == "Read" and names_out(fp):
            return None, ""
        if name == "Grep" and names_out(path):
            return None, ""
        if name == "Glob" and (names_out(path) if path else names_out(pat)):
            return None, ""
        return "explore", next((v for v in (fp, path, pat) if v), "")
    return None, ""


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: graph_first.py <trace.jsonl>\n")
        return 2
    try:
        calls = list(tool_calls(argv[1]))
    except OSError as exc:
        sys.stderr.write("cannot read trace: %s\n" % exc)
        return 2
    for name, inp in calls:
        kind, detail = classify(name, inp)
        if kind:
            detail = " ".join(detail.split())
            print("graph_first=%d" % (kind == "graph"))
            print("first=%s:%s" % (name, detail))
            return 0
    print("graph_first=0")
    print("first=none:")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
