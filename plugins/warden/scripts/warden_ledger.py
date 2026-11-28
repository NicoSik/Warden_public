"""The lessons ledger: one line per status change for a failure signature or a nudge.

warden-lesson loads this file by path, only inside the ledger commands. It sets WL to the lesson script module.
"""
import datetime
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

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
    out = {"entries": {}, "history": {}, "skipped": [], "invalid": [], "bad_regex": [], "readable": True}
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
    for slug, d in out["entries"].items():
        if d.get("status") not in STATUSES or d.get("kind") not in ("sig", "nudge"):
            out["invalid"].append(slug)
        elif d["kind"] == "sig" and not (isinstance(d.get("match"), str) and _match_compiles(d["match"])):
            out["bad_regex"].append(slug)
    out["invalid"].sort()
    out["bad_regex"].sort()
    out["skipped"] = sorted(out["invalid"] + out["bad_regex"])
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
            flagged_unmatched += 1 if r["flagged"] and not r["hidden"] else 0
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
        own = [x for r in block_rows.get(slug, []) for x in r["session_names"]] + [n["session"] for n in block_nudges.get(slug, [])]
        recurring.append({"entry": by_slug[slug], "after_sessions": _after_fix(by_slug[slug], own, days),
                          "rows": block_rows.get(slug, []), "nudges": block_nudges.get(slug, [])})
    recurring.sort(key=lambda b: b["entry"]["slug"])
    recurring.sort(key=lambda b: max(days[s] for s in b["after_sessions"]), reverse=True)
    footer = []
    if not led["readable"]:
        footer.append("ledger: unreadable")
    if led["bad_regex"]:
        footer.append("ledger: %d entries skipped (bad regex: %s)" % (len(led["bad_regex"]), ", ".join(led["bad_regex"])))
    if led["invalid"]:
        footer.append("ledger: %d entries skipped (invalid: %s)" % (len(led["invalid"]), ", ".join(led["invalid"])))
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


KEEP_REPORTS = 12
STALE_DAYS = 8
LABEL = "com.warden.lesson-weekly"
TEST_MARKER = "test-notify"
TEST_MAX_AGE = 300
KICKSTART_WAIT = 10
PLIST_TEMPLATE = {
    "Label": LABEL,
    "ProgramArguments": [],
    "StartCalendarInterval": {"Weekday": 1, "Hour": 9, "Minute": 15},
    "StandardErrorPath": "",
    "RunAtLoad": False,
}


def now():
    """Local time, or WARDEN_NOW when it is set."""
    text = os.environ.get("WARDEN_NOW")
    return datetime.datetime.fromisoformat(text) if text else datetime.datetime.now()


def _module(name):
    """Load a sibling module by path, once. The weekly run runs under python3 -I, so the folder is not on sys.path."""
    mod = sys.modules.get(name)
    if mod is None:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.realpath(__file__)), name + ".py")
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    return mod


def _suite_conf():
    given = os.environ.get("WARDEN_SUITE_CONF")
    if given:
        return given
    checkout = os.path.realpath(__file__)
    for _ in range(4):
        checkout = os.path.dirname(checkout)
    return os.path.join(checkout, "tests", "behavior", "evals", "suite.conf")


def _read_last_run():
    try:
        with open(os.path.join(weekly_dir(), "last-run"), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _version_lines(pins):
    """Return (lines, errors) for the suite coverage of the current pins."""
    model = pins["model"]
    if model == "unknown":
        return [], []
    suite = _module("warden_suite")
    try:
        cases = suite.read_suite_cases(_suite_conf())
    except OSError as e:
        return [], ["suite.conf unreadable: %s" % (e.strerror or e)]
    summaries, _bad = suite.load_summaries(os.path.join(WL.inbox(), "suite"))
    cli_minor = None if pins["cli_error"] else suite.minor(pins["cli_version"])
    if suite.is_covered(summaries, cases, model, cli_minor):
        return [], []
    found = suite.newest_covered(summaries, cases)
    if found is None:
        return ["No complete suite record yet. Run: warden-lesson suite"], []
    old_minor, old_model = found[0]
    lines = []
    if old_model != model:
        lines.append("Model changed: %s \u2192 %s. Run: warden-lesson suite" % (old_model, model))
    if cli_minor is not None and old_minor != cli_minor:
        lines.append("Claude Code %s \u2192 %s. Run: warden-lesson suite" % (old_minor, cli_minor))
    return lines, []


def _pins_text(pins):
    return "%s %s" % (pins.get("cli_version") or "unknown", pins.get("model") or "unknown")


def weekly_dir():
    return os.path.join(WL.inbox(), "weekly")


def notify(message):
    """Show a macOS notification. Return the exit code, or 127 when osascript is missing."""
    cmd = ["osascript", "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
           "-e", "end run", "Warden lessons", message]
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode
    except FileNotFoundError:
        return 127
    except (OSError, subprocess.SubprocessError):
        return 1


def _write_atomic(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _plural(n, one, many):
    return "%d %s" % (n, one if n == 1 else many)


def _test_mode():
    """Handle the test-notify marker. Return an exit code for a test run, or None for a normal run."""
    marker = os.path.join(weekly_dir(), TEST_MARKER)
    try:
        age = time.time() - os.stat(marker).st_mtime
    except OSError:
        return None
    if age >= TEST_MAX_AGE:
        try:
            os.remove(marker)
        except OSError:
            pass
        return None
    code = notify("Test notification from schedule install.")
    try:
        if code == 0:
            os.remove(marker)
        else:
            with open(marker, "w", encoding="utf-8") as f:
                f.write("notify failed: %d" % code)
    except OSError:
        pass
    return 0 if code == 0 else 1


def weekly_cmd(args):
    test = _test_mode()
    if test is not None:
        return test
    view = ledger_view(False)
    text = render_report(view)
    when = now()
    previous = _read_last_run()
    try:
        since = datetime.datetime.fromisoformat(previous["ts"]).astimezone()
    except (TypeError, KeyError, ValueError):
        since = (when - datetime.timedelta(days=7)).astimezone()
    home_dir = os.path.expanduser("~")
    pins = _module("warden_pins").current_pins(
        os.environ.get("WARDEN_CLAUDE"),
        os.environ.get("WARDEN_PROJECTS_DIR") or os.path.join(home_dir, ".claude", "projects"),
        os.environ.get("WARDEN_SETTINGS") or os.path.join(home_dir, ".claude", "settings.json"), since)
    version_lines, errors = _version_lines(pins)
    if pins["cli_error"]:
        errors.append(pins["cli_error"])
    old_text = _pins_text(previous) if previous and "model" in previous else "unknown unknown"
    if old_text == _pins_text(pins):
        text += "\npins: %s (%s), unchanged since the last weekly run" % (_pins_text(pins), pins["model_source"])
    else:
        text += "\npins: %s (%s), changed since the last weekly run (%s \u2192 %s)" % (
            _pins_text(pins), pins["model_source"], old_text, _pins_text(pins))
    folder = weekly_dir()
    report = os.path.join(folder, "report-%s.txt" % when.date())
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        _write_atomic(report, text + "\n")
    except OSError as e:
        errors.append("report write failed: %s" % (e.strerror or e))
    recurring, unack = len(view["recurring"]), view["unacknowledged"]
    notified = False
    if recurring + unack > 0 or version_lines:
        home = home_dir
        shown = "~" + report[len(home):] if report.startswith(home.rstrip("/") + "/") else report
        parts = []
        if recurring + unack > 0:
            parts.append("%s recurring, %s without an entry." % (
                _plural(recurring, "fixed entry", "fixed entries"), _plural(unack, "flagged signature", "flagged signatures")))
        message = "\n".join(parts + version_lines + [shown])
        code = notify(message)
        notified = code == 0
        if not notified:
            errors.append("notify failed: %d" % code)
    try:
        names = sorted(n for n in os.listdir(folder) if re.match(r"^report-.*\.txt$", n))
        for n in names[:-KEEP_REPORTS]:
            os.remove(os.path.join(folder, n))
    except OSError:
        pass
    last = {"ts": when.isoformat(timespec="seconds"), "report": report, "recurring": recurring,
            "unacknowledged": unack, "notified": notified, "cli_version": pins["cli_version"],
            "model": pins["model"], "model_source": pins["model_source"], "model_lines": pins["model_lines"]}
    if pins["cli_error"]:
        last["cli_error"] = pins["cli_error"]
    if errors:
        last["error"] = "; ".join(errors)
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        _write_atomic(os.path.join(folder, "last-run"), json.dumps(last))
    except OSError as e:
        print("weekly: last-run write failed: %s" % (e.strerror or e), file=sys.stderr)
        return 1
    return 1 if errors else 0


def _weekly_line():
    try:
        with open(os.path.join(weekly_dir(), "last-run"), encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return "weekly: never run"
    except OSError:
        return "weekly: last-run unreadable"
    try:
        d = json.loads(raw)
        ts = datetime.datetime.fromisoformat(d["ts"])
        r, u, sent = int(d["recurring"]), int(d["unacknowledged"]), bool(d["notified"])
        stale = (now() - ts) > datetime.timedelta(days=STALE_DAYS)
    except (ValueError, TypeError, KeyError, AttributeError):
        return "weekly: last-run unreadable"
    line = "weekly: last run %s, %s, %d unacknowledged, %s" % (
        ts.strftime("%Y-%m-%d %H:%M"), _plural(r, "recurring entry", "recurring entries"), u,
        "notified" if sent else "not notified")
    if d.get("error"):
        line += ", error: %s" % d["error"]
    return line + (" STALE" if stale else "")


def plist_path():
    folder = os.environ.get("WARDEN_LAUNCH_AGENTS") or os.path.expanduser("~/Library/LaunchAgents")
    return os.path.join(folder, LABEL + ".plist")


def _target():
    return "gui/%d/%s" % (os.getuid(), LABEL)


def _launchctl(*argv):
    """Run launchctl. Return (exit code, combined output); 127 when it is missing."""
    try:
        r = subprocess.run(["launchctl"] + list(argv), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=60)
    except FileNotFoundError:
        return 127, "launchctl: not found"
    except (OSError, subprocess.SubprocessError) as e:
        return 1, str(e)
    return r.returncode, r.stdout.strip()


def _refuse(message):
    print("schedule: refused, " + message)
    return 2


def _confirm():
    folder = weekly_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    _write_atomic(os.path.join(folder, "schedule.json"), json.dumps({"confirmed": now().isoformat(timespec="seconds")}))


def _install():
    bin_dir = os.path.expanduser("~/.claude/bin")
    if not os.path.exists(bin_dir):
        return _refuse("~/.claude/bin does not exist")
    checkout = os.path.dirname(os.path.realpath(bin_dir))
    if os.path.isfile(os.path.join(checkout, ".git")):
        return _refuse("%s is a git worktree; install from the main checkout" % checkout)
    script = os.path.join(checkout, "plugins", "warden", "scripts", "warden-lesson")
    if not os.path.exists(script):
        return _refuse("%s does not exist" % script)
    python = shutil.which("python3")
    if python is None:
        return _refuse("no python3 on PATH")
    folder = weekly_dir()
    data = dict(PLIST_TEMPLATE)
    data["ProgramArguments"] = [python, "-I", script, "weekly"]
    data["StandardErrorPath"] = os.path.join(folder, "launchd.err")
    claude = shutil.which("claude")
    if claude is None:
        print("claude not found; the version check is off")
    else:
        data["EnvironmentVariables"] = {"WARDEN_CLAUDE": claude}
    plist = plist_path()
    try:
        os.makedirs(os.path.dirname(plist), exist_ok=True)
        os.makedirs(folder, mode=0o700, exist_ok=True)
        tmp = plist + ".tmp"
        with open(tmp, "wb") as f:
            f.write(plistlib.dumps(data))
        os.chmod(tmp, 0o644)
        os.replace(tmp, plist)
    except OSError as e:
        print("schedule: write failed: %s" % (e.strerror or e))
        return 1
    uid = os.getuid()
    _launchctl("bootout", _target())
    code, out = _launchctl("bootstrap", "gui/%d" % uid, plist)
    if code != 0:
        print(out)
        return 1
    marker = os.path.join(folder, TEST_MARKER)
    try:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(fd)
    except OSError as e:
        print("schedule: write failed: %s" % (e.strerror or e))
        return 1
    code, out = _launchctl("kickstart", _target())
    if code != 0:
        _remove(marker)
        print(out)
        return 1
    limit = KICKSTART_WAIT
    deadline = time.time() + limit
    while os.path.exists(marker) and time.time() < deadline:
        failure = _marker_text(marker)
        if failure.startswith("notify failed:"):
            _remove(marker)
            print("schedule: the test notification failed (%s). Check System Settings > Notifications > Script Editor." % failure)
            return 1
        time.sleep(0.2)
    if os.path.exists(marker):
        _remove(marker)
        print("schedule: the launchd agent did not run the test within %d seconds. Check %s." % (
            limit, os.path.join(folder, "launchd.err")))
        return 1
    print("plist: %s\nscript: %s\ninterpreter: %s\nnext run: Monday 09:15" % (plist, script, python))
    if not sys.stdin.isatty():
        print("Run warden-lesson schedule confirm after you see the test notification.")
        return 0
    try:
        answer = input("Did you see the test notification? [y/N] ")
    except EOFError:
        answer = ""
    if answer.strip().lower() in ("y", "yes"):
        _confirm()
    else:
        print("Notifications from osascript appear under Script Editor. Allow them in System Settings > "
              "Notifications > Script Editor. If Script Editor is not listed, open Script Editor, run: "
              'display notification "test", and allow the prompt. Then run: warden-lesson schedule confirm')
    return 0


def _marker_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def _uninstall():
    plist = plist_path()
    if not os.path.exists(plist):
        print("schedule: not installed")
        return 0
    _launchctl("bootout", _target())
    _remove(plist)
    print("schedule: uninstalled")
    return 0


def schedule_cmd(args):
    try:
        if args.action == "install":
            return _install()
        if args.action == "uninstall":
            return _uninstall()
        _confirm()
        return 0
    except OSError as e:
        print("schedule: %s failed: %s" % (args.action, e.strerror or e), file=sys.stderr)
        return 1


def _schedule_line():
    try:
        with open(plist_path(), "rb") as f:
            argv = plistlib.load(f)["ProgramArguments"]
        python, script = str(argv[0]), str(argv[2])
    except FileNotFoundError:
        return "schedule: not installed"
    except (OSError, ValueError, KeyError, IndexError, TypeError, plistlib.InvalidFileException):
        return "schedule: broken (plist unreadable)"
    if not os.path.exists(script):
        return "schedule: broken (script missing: %s)" % script
    if not os.path.exists(python):
        return "schedule: broken (interpreter missing: %s)" % python
    try:
        with open(os.path.join(weekly_dir(), "schedule.json"), encoding="utf-8") as f:
            confirmed = bool(json.load(f).get("confirmed"))
    except (OSError, ValueError, AttributeError):
        confirmed = False
    return "schedule: installed, Monday 09:15" + ("" if confirmed else ", notification unconfirmed")


def _suite_line():
    suite = _module("warden_suite")
    summaries, _bad = suite.load_summaries(os.path.join(WL.inbox(), "suite"))
    if not summaries:
        return "suite: never run"
    newest = summaries[-1]
    line = "suite: last run %s on %s, %s. " % (str(newest["date"])[:10], newest["cli_version"], newest["model"])
    last = _read_last_run()
    if last and last.get("model"):
        return line + "Now %s, %s (%s)" % (last.get("cli_version") or "unknown", last["model"], last.get("model_source", "unknown"))
    return line + "Now unknown"


def _claude_warning():
    try:
        with open(plist_path(), "rb") as f:
            env = plistlib.load(f).get("EnvironmentVariables")
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
        return None
    if isinstance(env, dict) and env.get("WARDEN_CLAUDE"):
        return None
    return "version check: claude not found at schedule install"


def status_lines():
    lines = [_weekly_line(), _schedule_line(), _suite_line()]
    warning = _claude_warning()
    if warning:
        lines.append(warning)
    return lines
