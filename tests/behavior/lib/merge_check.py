#!/usr/bin/env python3
"""Check that a merged plugin holds every file of the warden plugin, byte-equal.

Usage: merge_check.py <warden_dir> <merged_dir>

Skips .claude-plugin/plugin.json, .claude-plugin/marketplace.json and hooks/hooks.json.
Exit: 0 complete (no output), 2 a file is missing or differs ("merge incomplete: <path>" on stderr).
"""
import filecmp
import os
import sys

SKIP = {".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json"}


def main(argv):
    if len(argv) != 3:
        print("usage: merge_check.py <warden_dir> <merged_dir>", file=sys.stderr)
        return 2
    warden, merged = argv[1], argv[2]
    rels = []
    for root, dirs, files in os.walk(warden):
        dirs.sort()
        for name in sorted(files):
            rels.append(os.path.relpath(os.path.join(root, name), warden).replace(os.sep, "/"))
    for rel in sorted(rels):
        if rel in SKIP:
            continue
        dst = os.path.join(merged, rel)
        if not os.path.isfile(dst) or not filecmp.cmp(os.path.join(warden, rel), dst, shallow=False):
            print("merge incomplete: " + rel, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
