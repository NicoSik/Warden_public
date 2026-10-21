"""Report whether a graph query came before the first exploration call in a trace."""
import json
import re
import shlex
import sys

EXPLORE_TOOLS = ("Read", "Grep", "Glob")
EXPLORE_CMD = re.compile(
    r"^\s*(?:git\s+(?:(?:-C\s+\S+|-c\s+\S+|--\S+)\s+)*(?P<git>grep|ls-files|ls-tree)"
    r"|(?P<verb>grep|egrep|fgrep|rg|find|cat|sed|awk|head|tail|ls|tree|wc|nl|less|more|fd|du))\b"
)
CD_CMD = re.compile(r"^\s*cd(\s+(\S+))?\s*$")
SPLIT = re.compile(r"(&&|\|\||;|\||\n)")
OUT = "graphify-out"
GRAPH_CMD = re.compile(
    r"^(\w+=\S*\s+)*"
    r"(?:env\s+(?:\w+=\S*\s+)*|timeout\s+\d+\S*\s+|uvx\s+(?:--from\s+\S+\s+)?"
    r"|uv\s+tool\s+run\s+(?:--from\s+\S+\s+)?|uv\s+run\s+|pipx\s+run\s+|python3?\s+-m\s+)*"
    r"(\S*/)?graphifyy?\s+(query|explain|path)\b"
)
REDIR = re.compile(r"^(\d*(>>?|<)&?\S*|&>>?\S*)$")
REDIR_OP = re.compile(r"^(\d*(>>?|<)|&>>?)$")
VALUE_FLAGS = {
    "tree": ("-L", "-I", "-P"),
    "head": ("-n", "-c"),
    "tail": ("-n", "-c"),
}
for _v in ("grep", "egrep", "fgrep", "rg", "git grep"):
    VALUE_FLAGS[_v] = ("-A", "-B", "-C", "-m", "-e", "-f", "-t", "-g", "--max-count", "--context", "--regexp", "--file")
NUMERIC = re.compile(r"^\+?\d+$")


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
    parts = token.split("/")
    if ".." in parts:
        return False
    if token.startswith("/"):
        return OUT in parts
    return token in (OUT, "./" + OUT) or token.startswith((OUT + "/", "./" + OUT + "/"))


def posix_tokens(rest):
    """Split like POSIX shlex. Return (raw, value) pairs; raise ValueError if a quote is open."""
    out = []
    raw, val, active = "", "", False
    quote = None
    i = 0
    while i < len(rest):
        c = rest[i]
        if quote == "'":
            raw += c
            if c == "'":
                quote = None
            else:
                val += c
        elif quote == '"':
            raw += c
            if c == '"':
                quote = None
            elif c == "\\" and i + 1 < len(rest) and rest[i + 1] in '\\"$`':
                i += 1
                raw += rest[i]
                val += rest[i]
            else:
                val += c
        elif c.isspace():
            if active:
                out.append((raw, val))
            raw, val, active = "", "", False
        else:
            active = True
            raw += c
            if c in "'\"":
                quote = c
            elif c == "\\" and i + 1 < len(rest):
                i += 1
                raw += rest[i]
                val += rest[i]
            else:
                val += c
        i += 1
    if quote:
        raise ValueError("unterminated quote")
    if active:
        out.append((raw, val))
    return out


def split_args(rest):
    """Tokenize like POSIX shlex, then drop redirections (judged on the raw text)."""
    try:
        toks = posix_tokens(rest)
    except ValueError:
        toks = [(t, t) for t in rest.split()]
    kept = []
    skip = False
    for raw, val in toks:
        if skip:
            skip = False
        elif raw[0] in "'\"":
            kept.append(val)  # a quoted word is always an operand
        elif REDIR_OP.match(raw):
            skip = True
        elif not REDIR.match(raw):
            kept.append(val)
    return kept


def operands(verb, args):
    """Return the path operands of an explore command, or None if it always explores."""
    if verb == "git ls-tree":
        return None
    if verb == "find":
        roots = []
        for t in args:
            if t.startswith(("-", "(", "!")):
                break
            roots.append(t)
        return roots
    plain, skip = [], False
    has_e = verb == "rg" and "--files" in args  # rg --files takes no pattern
    for t in args:
        if skip:
            skip = False
        elif t in VALUE_FLAGS.get(verb, ()):
            skip = True
            has_e = has_e or t in ("-e", "-f", "--regexp", "--file")
        elif t.startswith(("--regexp=", "--file=")) or re.match(r"^-[ef].", t):
            has_e = True
        elif not t.startswith("-"):
            plain.append(t)
    if verb in ("head", "tail", "tree"):
        plain = [t for t in plain if not NUMERIC.match(t)]
    if verb in ("sed", "awk", "fd"):
        return plain[1:]  # the first operand is the script or pattern
    if verb in ("grep", "egrep", "fgrep", "rg", "git grep"):
        return plain if has_e else plain[1:]
    return plain


def is_out_check(verb, rest, in_out):
    """True when an explore segment touches only graphify-out."""
    args = split_args(rest)
    if verb == "git ls-tree":
        return False
    if in_out:
        plain = [t for t in args if not t.startswith("-")]
        return all(".." not in t.split("/") and (not t.startswith("/") or names_out(t)) for t in plain)
    paths = operands(verb, args)
    return bool(paths) and all(names_out(t) for t in paths)


def join_lines(cmd):
    """Join continued lines; a comment line never continues."""
    out = ""
    for line in cmd.split("\n"):
        body = line.rstrip()
        if line.lstrip().startswith("#"):
            out += line + "\n"
        elif body.endswith("\\"):
            out += body[:-1] + " "
        elif body.endswith(("|", "&&")):
            out += body
        else:
            out += line + "\n"
    return out


def bash_first(cmd):
    """Return 'graph', 'explore' or None for the first segment that is either."""
    parts = SPLIT.split(join_lines(cmd))
    in_out = False  # set by cd graphify-out, for the rest of the command
    clear = False  # the previous segment closed a subshell
    # parts alternate: segment, separator, segment, ...
    for i in range(0, len(parts), 2):
        if clear:
            in_out, clear = False, False
        seg = parts[i].strip().lstrip("(").strip()
        if seg.endswith(")"):
            clear = True
            seg = seg.rstrip(")").strip()
        if i >= 2 and parts[i - 1] == "|":
            continue  # a pipe stage reads stdin; the first command decides
        if not seg or seg.startswith("#"):
            continue
        if GRAPH_CMD.search(seg):
            return "graph"
        cd = CD_CMD.match(seg)
        if cd:
            in_out = bool(cd.group(2)) and names_out(cd.group(2))
            continue
        m = EXPLORE_CMD.match(seg)
        if not m:
            continue
        verb = ("git " + m.group("git")) if m.group("git") else m.group("verb")
        if is_out_check(verb, seg[m.end():], in_out):
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
        if name == "Glob":
            bare = pat[3:] if pat.startswith("**/") else pat
            if names_out(path) or (names_out(bare) and (not path or path.startswith("/"))):
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
