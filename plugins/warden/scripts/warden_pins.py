"""Read the current Claude Code version and model without a model call (REQ-4).

Stdlib only, no side effects at import. From a transcript it keeps only the
model ID and a line count (REQ-4.7). It never writes a file.
"""
import datetime
import json
import os
import re
import subprocess

_VERSION_RE = re.compile(r"\d+\.\d+\.\d+")


def cli_version(claude_path, timeout=10):
    """Return (version, raw first line, error)."""
    if not claude_path:
        return None, None, "claude not found at schedule install"
    try:
        proc = subprocess.run([claude_path, "--version"], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, None, "claude --version failed: timed out after %ss" % timeout
    except OSError as e:
        return None, None, "claude --version failed: %s" % (e.strerror or e.__class__.__name__)
    out = proc.stdout.decode("utf-8", "replace").strip()
    raw = out.splitlines()[0].strip() if out else None
    if proc.returncode != 0:
        return None, raw, "claude --version failed: exit %d" % proc.returncode
    m = _VERSION_RE.search(raw or "")
    if not m:
        return None, raw, "claude --version failed: no version number"
    return m.group(0), raw, None


def _parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        t = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t


def session_model(projects_dir, since):
    """Most common model among main-session lines at or after `since`, and their count."""
    since_epoch = since.timestamp()
    counts = {}
    newest = {}
    total = 0
    for root, dirs, files in os.walk(projects_dir):
        if "subagents" in dirs:
            dirs.remove("subagents")
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            try:
                if os.stat(path).st_mtime < since_epoch:
                    continue
                fh = open(path, encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh:
                for raw in fh:
                    try:
                        d = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isSidechain") is True:
                        continue
                    msg = d.get("message")
                    model = msg.get("model") if isinstance(msg, dict) else None
                    if not isinstance(model, str) or not model or model == "<synthetic>":
                        continue
                    ts = _parse_ts(d.get("timestamp"))
                    if ts is None or ts < since:
                        continue
                    total += 1
                    counts[model] = counts.get(model, 0) + 1
                    if model not in newest or ts > newest[model]:
                        newest[model] = ts
    if not counts:
        return None, 0
    best = max(counts, key=lambda m: (counts[m], newest[m]))
    return best, total


def settings_model(settings_path):
    """The `model` key when it is a full model ID, otherwise "unknown"."""
    try:
        with open(settings_path, encoding="utf-8") as fh:
            value = json.load(fh).get("model")
    except (OSError, ValueError, AttributeError):
        return "unknown"
    if isinstance(value, str) and value.startswith("claude-") and any(c.isdigit() for c in value):
        return value
    return "unknown"


def current_pins(claude_path, projects_dir, settings_path, since):
    version, raw, error = cli_version(claude_path)
    model, lines = session_model(projects_dir, since)
    if lines > 0:
        source = "logs"
    else:
        model = settings_model(settings_path)
        source = "unknown" if model == "unknown" else "settings"
        lines = 0
    return {"cli_version": version, "cli_version_raw": raw, "cli_error": error,
            "model": model, "model_source": source, "model_lines": lines}
