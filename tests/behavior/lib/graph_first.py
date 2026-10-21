"""Report whether a graph query came before the first exploration call in a trace."""
import json
import re
import sys

EXPLORE_TOOLS = ("Read", "Grep", "Glob")
EXPLORE_CMD = re.compile(r"^\s*(grep|rg|find|cat|sed|head|ls|tail|git\s+grep|git\s+ls-files)\b")
SPLIT = re.compile(r"(&&|\|\||;|\|)")
OUT = "graphify-out/"
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


def bash_explores(cmd):
    parts = SPLIT.split(cmd)
    # parts alternate: segment, separator, segment, ...
    for i in range(0, len(parts), 2):
        if i >= 2 and parts[i - 1] == "|":
            continue  # a pipe stage reads stdin; the first command decides
        seg = parts[i].strip()
        if not EXPLORE_CMD.match(seg):
            continue
        paths = [t for t in seg.split()[1:] if "/" in t]
        if paths and all(OUT in t for t in paths):
            continue
        if not paths and OUT in seg:
            continue
        return True
    return False


def classify(name, inp):
    """Return ('graph'|'explore'|None, detail)."""
    if name == "Bash":
        cmd = str(inp.get("command", ""))
        if GRAPH_CMD.search(cmd):
            return "graph", cmd
        if bash_explores(cmd):
            return "explore", cmd
        return None, cmd
    if name in EXPLORE_TOOLS:
        vals = [str(inp.get(k) or "") for k in ("file_path", "path", "pattern")]
        if any(OUT in v for v in vals):
            return None, ""
        return "explore", next((v for v in vals if v), "")
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
