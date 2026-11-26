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
        out["entries"].pop(slug, None)  # Dict order follows each slug's latest line.
        out["entries"][slug] = d
        out["history"].setdefault(slug, []).append(d)
    out["skipped"] = sorted(
        s for s, d in out["entries"].items()
        if d.get("kind") == "sig" and not (isinstance(d.get("match"), str) and _match_compiles(d["match"])))
    return out


def session_days():
    """Map each session name to the local date of its first parsed line's ts."""
    out = {}
    files, _ = WL._log_files()
    for f in files:
        lines = WL._read_lines(f)
        if not lines:
            continue
        try:
            ts = datetime.datetime.strptime(str(lines[0].get("ts")), "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            continue
        out[os.path.basename(f)[:-len(".jsonl")]] = ts.replace(tzinfo=datetime.timezone.utc).astimezone().date()
    return out


def _after_fix(entry, sessions, days):
    """Return the sorted sessions whose day is later than the entry's fixed_on."""
    if not _valid_date(entry.get("fixed_on")):
        return []
    fixed = datetime.date.fromisoformat(entry["fixed_on"])
    return sorted(s for s in set(sessions) if s in days and days[s] > fixed)


def _build(include_hidden):
    """Return (view, matches). matches maps each usable slug to {"rows", "nudges", "after"}, before winners."""
    rows, lessons, hidden = WL.report_rows(include_hidden=True)
    nudges = WL.nudge_rows()
    hidden = dict(hidden)
    led = read_ledger()
    days = session_days()
    skipped = set(led["skipped"])
    entries = [(i, e) for i, e in enumerate(led["entries"].values()) if e.get("slug") not in skipped]
    matches = {}
    for _, e in entries:
        if e.get("kind") == "nudge":
            mr, mn = [], [n for n in nudges if not n["followed"]]
        elif e.get("kind") == "sig":
            mr, mn = [r for r in rows if re.search(e["match"], r["norm"])], []
        else:
            continue
        after = _after_fix(e, [x for r in mr for x in r["session_names"]] + [n["session"] for n in mn], days)
        matches[e["slug"]] = {"rows": mr, "nudges": mn, "after": after}
    order = {e["slug"]: (str(e.get("ts") or ""), i) for i, e in entries if e["slug"] in matches}
    by_slug = {e["slug"]: e for _, e in entries}

    def winner(found):
        best = [s for s, m in matches.items() if found(m)]
        return max(best, key=lambda s: order[s]) if best else None

    block_rows, block_nudges, main_rows = {}, {}, []
    flagged_unmatched = 0
    for r in rows:
        slug = winner(lambda m: any(x is r for x in m["rows"]))
        e = by_slug.get(slug)
        if e is None:
            flagged_unmatched += 1 if r["flagged"] else 0
        elif e["status"] in ("fixed", "verified") and _after_fix(e, r["session_names"], days):
            if r["hidden"]:
                hidden[r["hidden"]] = hidden.get(r["hidden"], 0) - 1
            r["hidden"] = None
            block_rows.setdefault(slug, []).append(r)
            continue
        elif e["status"] == "ignored":
            if not r["hidden"]:
                r["hidden"] = "ignored"
                hidden["ignored"] = hidden.get("ignored", 0) + 1
        else:
            r["ledger_tag"] = "%s:%s" % (slug, e["status"])
        main_rows.append(r)
    main_nudges = []
    for n in nudges:
        slug = winner(lambda m: any(x is n for x in m["nudges"]))
        e = by_slug.get(slug)
        if e is not None and e["status"] in ("fixed", "verified") and _after_fix(e, [n["session"]], days):
            block_nudges.setdefault(slug, []).append(n)
        else:
            main_nudges.append(n)
    recurring = []
    for slug in set(block_rows) | set(block_nudges):
        recurring.append({"entry": by_slug[slug], "after_sessions": matches[slug]["after"],
                          "rows": block_rows.get(slug, []), "nudges": block_nudges.get(slug, [])})
    recurring.sort(key=lambda b: b["entry"]["slug"])
    recurring.sort(key=lambda b: max(days[s] for s in b["after_sessions"]), reverse=True)
    footer = []
    if not led["readable"]:
        footer.append("ledger: unreadable")
    if led["skipped"]:
        footer.append("ledger: %d entries skipped (bad regex: %s)" % (len(led["skipped"]), ", ".join(led["skipped"])))
    if not include_hidden:
        main_rows = [r for r in main_rows if not r["hidden"]]
    view = {"recurring": recurring, "rows": main_rows, "lessons": lessons, "nudges": main_nudges,
            "hidden": hidden, "footer": footer, "unacknowledged": flagged_unmatched}
    return view, matches


def ledger_view(include_hidden):
    return _build(include_hidden)[0]


def render_report(view):
    """Return the report text: the recurring blocks, the usual report, then the footer."""
    out = []
    if view["recurring"]:
        out.append("Fixed but recurring:")
        for b in view["recurring"]:
            e = b["entry"]
            head = [e["status"]]
            if e.get("pr") is not None:
                head.append("#%s" % e["pr"])
            head.append(e.get("fixed_on", ""))
            n = len(b["after_sessions"])
            out.append("!!  %s  %s  %d session%s after fix" % (e["slug"], " ".join(head), n, "" if n == 1 else "s"))
            out.extend("      " + WL.row_line(r) for r in b["rows"])
            out.extend("      " + WL.nudge_line(x) for x in b["nudges"])
        out.append("")
    out.extend(WL.format_report(view["rows"], view["lessons"], view["nudges"], view["hidden"]))
    out.extend(view["footer"])
    return "\n".join(out)


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
    _print_matches(line)
    return 0


def _print_matches(line):
    matches = _build(True)[1]
    m = matches.get(line["slug"])
    if m is None:
        return
    found = m["nudges"] if line["kind"] == "nudge" else m["rows"]
    sessions = {s for r in m["rows"] for s in r["session_names"]} | {n["session"] for n in m["nudges"]}
    print("  matches: %d %s, %d sessions, %d after fix" % (
        len(found), "nudges" if line["kind"] == "nudge" else "signatures", len(sessions), len(m["after"])))
    for x in found[:10]:
        print("  " + (WL.nudge_line(x) if line["kind"] == "nudge" else WL.row_line(x)))
    if len(found) > 10:
        print("  +%d more" % (len(found) - 10))
    for slug in sorted(m2 for m2, o in matches.items() if m2 != line["slug"]
                       and any(r is x for r in o["rows"] for x in m["rows"])):
        print("mark: warning, also matched by " + slug)
