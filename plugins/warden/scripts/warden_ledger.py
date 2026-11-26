"""The lessons ledger: one line per status change for a failure signature or a nudge.

warden-lesson loads this file by path, only inside the ledger commands. It sets WL to the lesson script module.
"""
import datetime
import json
import os
import re
import sys

WL = None  # Set by warden-lesson's _ledger() before any function here runs.

STATUSES = ("open", "fixed", "verified", "ignored")
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
GUARDED_KEYS = ("slug", "kind", "match", "status", "pr", "fixed_on")


def ledger_path():
    return os.path.join(WL.inbox(), "ledger.jsonl")


def _match_compiles(match):
    try:
        re.compile(match)
        return True
    except (re.error, TypeError):
        return False


def read_ledger():
    """Read the ledger. The latest line per slug wins."""
    out = {"entries": {}, "history": {}, "skipped": [], "readable": True}
    path = ledger_path()
    try:
        open(path, encoding="utf-8").close()
    except FileNotFoundError:
        return out
    except OSError:
        out["readable"] = False
        return out
    for d in WL._read_lines(path):
        slug = d.get("slug")
        if not isinstance(slug, str) or not slug:
            continue
        out["entries"][slug] = d
        out["history"].setdefault(slug, []).append(d)
    out["skipped"] = sorted(
        s for s, d in out["entries"].items()
        if d.get("kind") == "sig" and not (isinstance(d.get("match"), str) and _match_compiles(d["match"])))
    return out


def _list_line(d):
    parts = [str(d.get("slug", "")), str(d.get("status", ""))]
    if d.get("pr") is not None:
        parts.append("#%s" % d["pr"])
    if d.get("fixed_on"):
        parts.append(str(d["fixed_on"]))
    parts.append(str(d.get("kind", "")))
    if d.get("note"):
        parts.append(str(d["note"]))
    return " ".join(parts)


def _die(message, code=2):
    print("mark: " + message, file=sys.stderr)
    return code


def _valid_date(text):
    if not isinstance(text, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", text):
        return False
    try:
        datetime.date.fromisoformat(text)
        return True
    except ValueError:
        return False


def mark_cmd(args):
    led = read_ledger()
    if not led["readable"]:
        return _die("the ledger cannot be read", 1)
    if args.list:
        for slug in sorted(led["entries"]):
            print(_list_line(led["entries"][slug]))
        return 0
    slug, status = args.slug, args.status
    if args.history:
        lines = led["history"].get(slug or "")
        if not lines:
            return _die("no line for slug %r" % slug)
        for d in lines:
            print(json.dumps(d, ensure_ascii=False))
        return 0
    if not slug or not SLUG_RE.match(slug):
        return _die("slug must match ^[a-z0-9]+(-[a-z0-9]+)*$")
    if status not in STATUSES:
        return _die("status must be one of: " + ", ".join(STATUSES))
    if args.match is not None and args.nudge:
        return _die("give --match or --nudge, not both")
    cur = led["entries"].get(slug)
    if cur is None and args.match is None and not args.nudge:
        return _die("a new slug needs --match or --nudge")
    cur = cur or {}
    if args.nudge:
        kind, match = "nudge", None
    elif args.match is not None:
        kind, match = "sig", args.match
    else:
        kind = cur.get("kind") if cur.get("kind") in ("sig", "nudge") else "sig"
        match = cur.get("match") if kind == "sig" else None
    pr = args.pr if args.pr is not None else cur.get("pr")
    fixed_on = args.fixed_on if args.fixed_on is not None else cur.get("fixed_on")
    note = args.note if args.note is not None else cur.get("note", "")
    if status in ("fixed", "verified") and not _valid_date(fixed_on):
        return _die("%s needs a fixed_on date in YYYY-MM-DD form" % status)
    if fixed_on is not None and not _valid_date(fixed_on):
        return _die("fixed_on must be a date in YYYY-MM-DD form")
    if status == "ignored" and not note:
        return _die("ignored needs a non-empty --note")
    if kind == "sig" and not (isinstance(match, str) and _match_compiles(match)):
        return _die("match is not a valid regular expression")
    line = {"slug": slug, "kind": kind}
    if kind == "sig":
        line["match"] = match
    line["status"] = status
    if pr is not None:
        line["pr"] = pr
    if fixed_on:
        line["fixed_on"] = fixed_on
    line["note"] = note if isinstance(note, str) else ""
    line["ts"] = WL._now()
    data = WL._fit(line)
    out = None
    if data is not None:
        try:
            out = json.loads(data.decode("utf-8"))
        except ValueError:
            out = None
    if out is None:
        changed = list(GUARDED_KEYS)
    else:
        changed = [k for k in GUARDED_KEYS if out.get(k) != line.get(k)]
    if changed:
        return _die("refused, the line changed in the secret scrub or the 512-byte cap: " + ", ".join(changed))
    if out.get("note") != line["note"]:
        line["note"] = out.get("note", "")
        print("mark: note scrubbed or shortened")
    if not WL.write_line(ledger_path(), line):
        print("warden-lesson: capture is disabled; run warden-lesson status", file=sys.stderr)
        return 1
    print(_list_line(line))
    return 0
