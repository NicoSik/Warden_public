#!/usr/bin/env python3
"""Grade `claude plugin eval --json` results and write the run record.

Usage: record.py --conf FILE --out-dir DIR --runs N --graphify-version V
                 --fixture-hash H --id ID --result SHA=FILE [--result ...]

FILE lines of --conf: <case> <baseline-sha or -> <candidate-sha> <at-least|at-most> <count>.
Exit: 0 all criteria met, 1 a candidate criterion failed, 2 bad or partial result.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH_FIRST = os.path.join(HERE, "graph_first.py")

LABEL = "list-price estimate; not billed on a subscription login, uses your plan's usage limits"
ATTEMPTS = ("Runs measure attempts. Inside the eval sandbox on macOS, git, the home-installed "
            "Graphify binary, and `.git/config` writes are blocked, so `graphify-setup` and "
            "`graphify query` fail inside a run.")


PATH_RE = re.compile(r"(?:~|(?<![\w.~]))/[^\s()]+")


def redact(text):
    """Replace absolute and home paths, since run records go into a public repo."""
    return PATH_RE.sub("<path>", str(text))


def graph_first(trace):
    """Return (value, first) for one trace; value None when it cannot be read."""
    if not trace or not os.path.isfile(trace):
        return None, "no trace"
    p = subprocess.run([sys.executable, "-I", GRAPH_FIRST, trace], capture_output=True, text=True)
    if p.returncode != 0:
        return None, "unreadable trace"
    lines = p.stdout.splitlines()
    val = None
    first = ""
    for ln in lines:
        if ln.startswith("graph_first="):
            val = int(ln.split("=", 1)[1])
        elif ln.startswith("first="):
            first = ln.split("=", 1)[1].split(":", 1)[0]  # tool name only: the input is transcript text
    return val, first


def first_commands(trace, limit=5):
    """Return the first tool calls of a trace as display lines. Terminal only, never recorded."""
    spec = importlib.util.spec_from_file_location("graph_first", GRAPH_FIRST)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    lines = []
    for name, inp in mod.tool_calls(trace):
        if len(lines) >= limit:
            break
        val = inp.get("command") or inp.get("file_path") or inp.get("path") or inp.get("pattern") or ""
        lines.append(("  %s: %s" % (name, " ".join(str(val).split())))[:160])
    return lines


def remove_tree(d):
    """Delete an eval temp dir. Plugin eval leaves some subdirs at mode 000,
    and the run dir itself read-only, so give the owner access back first."""
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    for root, dirs, _files in os.walk(d, topdown=True, onerror=lambda e: None):
        for name in dirs:
            try:
                os.chmod(os.path.join(root, name), 0o700)
            except OSError:
                pass
    shutil.rmtree(d, ignore_errors=True)


def cleanup(results):
    for res in results.values():
        for c in res.get("cases", []):
            for runs in (c.get("arms") or {}).values():
                for r in runs:
                    tp = r.get("tracePath")
                    if not tp:
                        continue
                    d = os.path.dirname(os.path.dirname(tp))
                    if os.path.basename(d).startswith("e-") and os.path.isdir(d):
                        remove_tree(d)


def grade_run(case, rule, run):
    """Return (hit, detail). hit is True/False, or None for an errored run (counted in neither direction)."""
    if run.get("error"):
        return None, "errored (%s)" % redact(run.get("error"))
    if case.startswith("read-order"):
        val, first = graph_first(run.get("tracePath"))
        if val is None:
            return None, "errored (graph_first unavailable: %s)" % first
        return val == 1, "graph_first=%d first=%s" % (val, first)
    for g in run.get("graders") or []:
        if g.get("name") == "triggered":
            trig = bool(g.get("passed")) if rule == "at-least" else not bool(g.get("passed"))
            return trig, "triggered=%s" % ("yes" if trig else "no")
    return None, "errored (no triggered grader)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--graphify-version", required=True)
    ap.add_argument("--fixture-hash", required=True)
    ap.add_argument("--id", required=True)
    ap.add_argument("--raw-dir", default="")
    ap.add_argument("--result", action="append", default=[])
    a = ap.parse_args()

    results = {}
    bad = []
    for item in a.result:
        sha, _, path = item.partition("=")
        try:
            with open(path) as f:
                results[sha] = json.load(f)
        except (OSError, ValueError) as e:
            bad.append("result for %s unreadable: %s" % (sha[:7], e))
    try:
        for sha, res in results.items():
            if not isinstance(res, dict) or "cases" not in res:
                bad.append("result for %s has no cases" % sha[:7])
            elif res.get("partial"):
                bad.append("result for %s is partial" % sha[:7])
        if bad:
            for b in bad:
                print("error: " + b, file=sys.stderr)
            return 2

        conf = []
        with open(a.conf) as f:
            for ln in f:
                p = ln.split()
                if len(p) == 5:
                    conf.append(p)

        versions = {r.get("claudeVersion") for r in results.values()}
        models = {(r.get("suite") or {}).get("modelOverride") or "account default" for r in results.values()}
        shas = []
        for case, base, cand, rule, count in conf:
            for s in (base, cand):
                if s != "-" and s not in shas:
                    shas.append(s)

        rows = []
        run_lines = []
        terminal = []
        total_cost = 0.0
        failed = False
        for case, base, cand, rule, count in conf:
            arms = (("candidate", cand),) if base == "-" else (("baseline", base), ("candidate", cand))
            for arm, sha in arms:
                item = None
                for c in results[sha]["cases"]:
                    if c.get("name") == case:
                        item = c
                if item is None:
                    print("error: case %s missing from result for %s" % (case, sha[:7]), file=sys.stderr)
                    return 2
                runs = (item.get("arms") or {}).get("with") or []
                hits = 0
                errored = 0
                for i, r in enumerate(runs, 1):
                    hit, detail = grade_run(case, rule, r)
                    if case.startswith("read-order"):
                        terminal.append("first commands: %s / %s / run %d" % (case, arm, i))
                        tp = r.get("tracePath")
                        if tp and os.path.isfile(tp):
                            terminal.extend(first_commands(tp))
                    if hit is None:
                        errored += 1
                    elif hit:
                        hits += 1
                    cost = r.get("costUsd") or 0
                    total_cost += cost
                    run_lines.append("- %s / %s / run %d: %s; score %s; passed %s; turns %s; cost $%.4f%s" % (
                        case, arm, i, detail, r.get("score"), r.get("passed"), r.get("turns"), cost,
                        "; error: %s" % redact(r.get("error")) if r.get("error") else ""))
                what = "graph-first" if case.startswith("read-order") else "triggered"
                op = ">=" if rule == "at-least" else "<="
                if arm == "candidate":
                    ok = hits >= int(count) if rule == "at-least" else hits <= int(count)
                    if errored:
                        ok = False
                    verdict = "PASS" if ok else "FAIL"
                    failed = failed or not ok
                    crit = "%s %s %s" % (what, op, count)
                else:
                    verdict = "report only"
                    crit = "(%s %s %s)" % (what, op, count)
                rows.append((case, arm, sha, "%d/%d%s" % (hits, len(runs), " (%d errored)" % errored if errored else ""), crit, verdict))

        today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        out = []
        out.append("# Behavior baseline run %s-%s" % (today, a.id))
        out.append("")
        out.append(ATTEMPTS)
        out.append("")
        out.append("## Pins")
        out.append("")
        out.append("- Claude Code version: %s" % ", ".join(sorted(v for v in versions if v)))
        out.append("- Model: %s" % ", ".join(sorted(models)))
        for s in shas:
            roles = []
            for case, base, cand, rule, count in conf:
                if s == base:
                    roles.append("baseline of %s" % case)
                if s == cand:
                    roles.append("candidate of %s" % case)
            out.append("- Arm commit %s (%s)" % (s, "; ".join(roles)))
        out.append("- graphify --version: %s" % a.graphify_version)
        out.append("- Fixture tree hash: %s" % a.fixture_hash)
        out.append("- Runs per case and arm: %s" % a.runs)
        out.append("")
        out.append("## Results")
        out.append("")
        out.append("| case | arm | SHA | count/runs | criterion | result |")
        out.append("|---|---|---|---|---|---|")
        for case, arm, sha, cr, crit, verdict in rows:
            out.append("| %s | %s | %s | %s | %s | %s |" % (case, arm, sha[:7], cr, crit, verdict))
        out.append("")
        out.append("## Runs")
        out.append("")
        out.extend(run_lines)
        out.append("")
        out.append("## Cost")
        out.append("")
        out.append("US$%.2f (%s)" % (total_cost, LABEL))
        if a.raw_dir:
            out.append("")
            out.append("Raw result JSON is kept outside the repository.")
        out.append("")
        text = "\n".join(out)

        os.makedirs(a.out_dir, exist_ok=True)
        path = os.path.join(a.out_dir, "%s-%s.md" % (today, a.id))
        with open(path, "w") as f:
            f.write(text)
        print("\n".join(out[out.index("| case | arm | SHA | count/runs | criterion | result |"):out.index("## Runs") - 1]))
        print("record: " + path)
        if terminal:
            print("\n".join(terminal))
        return 1 if failed else 0
    finally:
        cleanup(results)


if __name__ == "__main__":
    sys.exit(main())
