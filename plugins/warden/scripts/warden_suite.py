"""Suite summary reader, combined view and coverage. Stdlib only, no side effects at import."""
import json
import os
import re

REQUIRED = ("schema", "id", "date", "sha", "cli_version", "model", "cases")


def parse_cli_version(raw):
    m = re.search(r"\d+\.\d+\.\d+", raw or "")
    return m.group(0) if m else None


def minor(version):
    if not version:
        return None
    parts = version.split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else None


def read_suite_cases(conf_path):
    cases = []
    with open(conf_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            cases.append(line.split()[0])
    return cases


def load_summaries(folder):
    good, bad = [], []
    try:
        names = sorted(n for n in os.listdir(folder) if n.endswith(".json"))
    except OSError:
        return [], []
    for name in names:
        path = os.path.join(folder, name)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            bad.append(path)
            continue
        if not isinstance(data, dict) or any(k not in data for k in REQUIRED) \
                or not isinstance(data["cases"], list):
            bad.append(path)
            continue
        good.append((data["date"], name, data))
    good.sort(key=lambda t: (t[0], t[1]))
    return [t[2] for t in good], bad


def combined_view(summaries):
    view = {}
    for s in summaries:  # oldest first
        for e in s["cases"]:
            if e.get("arm") != "main":
                continue
            old = view.get(e["case"])
            if e["result"] == "ERRORED" and old is not None and old["result"] != "ERRORED":
                continue
            view[e["case"]] = {"result": e["result"], "count": e["count"],
                               "runs": e["runs"], "errored": e["errored"], "id": s["id"]}
    return view


def group(summaries, key):
    groups = {}
    for s in summaries:
        groups.setdefault(key(s), []).append(s)
    return sorted(groups.items(), key=lambda kv: max(s["date"] for s in kv[1]))


def full_pins(s):
    return (s["cli_version"], s["model"])


def minor_pins(s):
    return (minor(s["cli_version"]), s["model"])


def is_covered_view(view, cases):
    return all(c in view and view[c]["result"] != "ERRORED" for c in cases)


def newest_covered(summaries, cases):
    for key, members in reversed(group(summaries, minor_pins)):
        if is_covered_view(combined_view(members), cases):
            return key, members
    return None


def is_covered(summaries, cases, model, cli_minor):
    for key, members in group(summaries, minor_pins):
        if key[1] != model or (cli_minor is not None and key[0] != cli_minor):
            continue
        if is_covered_view(combined_view(members), cases):
            return True
    return False
