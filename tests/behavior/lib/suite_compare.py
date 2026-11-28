#!/usr/bin/env python3
"""Compare a suite summary with the newest earlier summary group that has different pins.

Usage: suite_compare.py --folder DIR --new ID --repo REPO
Prints to stdout. Exits 0, or 2 for a usage error or an unknown --new.
"""
import argparse
import importlib.util
import os
import subprocess
import sys


def load_suite():
    root = os.path.realpath(__file__)
    for _ in range(4):  # lib -> behavior -> tests -> repo
        root = os.path.dirname(root)
    path = os.path.join(root, "plugins", "warden", "scripts", "warden_suite.py")
    spec = importlib.util.spec_from_file_location("warden_suite", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git_ok(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode


def plugin_line(repo, old, new):
    if git_ok(repo, "cat-file", "-e", old + "^{commit}") != 0:
        return "plugin files: unknown (%s not found)" % old[:7]
    rc = git_ok(repo, "diff", "--quiet", old, new, "--", "plugins/")
    if rc == 0:
        return "plugin files: unchanged"
    if rc == 1:
        return "plugin files: changed between %s and %s" % (old[:7], new[:7])
    return "plugin files: unknown (%s not found)" % old[:7]


def fmt(v):
    return "%s/%s %s" % (v["count"], v["runs"], v["result"]) if v else "-"


def rows(old_view, new_view, old_label="old", new_label="new"):
    out = []
    for case in sorted(set(old_view) | set(new_view)):
        o, n = old_view.get(case), new_view.get(case)
        line = "%s | %s: %s (%s) | %s: %s (%s)" % (
            case, old_label, fmt(o), o["id"] if o else "-", new_label, fmt(n), n["id"] if n else "-")
        if o is None:
            line += " | new case"
        elif n is None:
            line += " | not in old record"
        elif "ERRORED" in (o["result"], n["result"]):
            bad = n if n["result"] == "ERRORED" else o
            line += " | not comparable (%s errored)" % bad["errored"]
            line += " | rerun: warden-lesson suite --case %s" % case
        elif o["result"] == "PASS" and n["result"] == "FAIL":
            line += " | FLIPPED"
        out.append(line)
    return out


def arm_view(summary, arm):
    view = {}
    for e in summary["cases"]:
        if e.get("arm") == arm:
            view[e["case"]] = {"result": e["result"], "count": e["count"], "runs": e["runs"],
                               "errored": e["errored"], "id": summary["id"]}
    return view


def side(label, members):
    ids = ", ".join(s["id"] for s in members)
    newest = members[-1]
    return "%s: %s | sha %s | cli %s | model %s" % (
        label, ids, newest["sha"][:7], newest["cli_version"], newest["model"])


def main():
    ap = argparse.ArgumentParser(prog="suite_compare.py")
    ap.add_argument("--folder", required=True)
    ap.add_argument("--new", required=True)
    ap.add_argument("--repo", required=True)
    args = ap.parse_args()

    ws = load_suite()
    summaries, bad = ws.load_summaries(args.folder)
    for path in bad:
        print("skipped unreadable summary: %s" % os.path.basename(path), file=sys.stderr)
    new = next((s for s in summaries if s["id"] == args.new), None)
    if new is None:
        print("suite_compare.py: summary %s not found in %s" % (args.new, args.folder), file=sys.stderr)
        return 2

    groups = ws.group(summaries, ws.full_pins)
    keys = [k for k, _ in groups]
    idx = keys.index(ws.full_pins(new))
    new_members = groups[idx][1]
    old_members = groups[idx - 1][1] if idx > 0 else None

    if old_members is None:
        print("no earlier suite record with different pins")
        others = [s for s in new_members if s["id"] != new["id"]]
        if others:
            print("newest same-pins summary: %s" % others[-1]["id"])
    else:
        print(side("old", old_members))
        print(side("new", new_members))
        print(plugin_line(args.repo, old_members[-1]["sha"], new_members[-1]["sha"]))
        for line in rows(ws.combined_view(old_members), ws.combined_view(new_members)):
            print(line)

    ab_models = sorted({e.get("model") for e in new["cases"] if e.get("arm") == "ab"} - {None})
    if any(e.get("arm") == "ab" for e in new["cases"]):
        print()
        print("A/B: %s against %s" % (", ".join(ab_models) or "unknown", new["model"]))
        for line in rows(arm_view(new, "main"), arm_view(new, "ab"), "main", "ab"):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
