#!/usr/bin/env python3
"""Merge Hugging Face /api/models list responses into browser table rows.

The shell (aichat.hf.browse.library.sh) does the curl - the bundled Python's urllib has
no CA bundle, but system curl uses the system trust store - and passes the saved JSON
file(s) here. One file for a single-format query (gguf or mlx), two for the "Any" union
(gguf + mlx), which this dedups by repo id and re-orders.

Usage:
    hf_models_query.py <order> <limit> <json_file>...

    order: "downloads" - merge all files, sort by download count desc (the field is always
             present, so this is a true global ordering).
           "rank"      - each input file is already API-sorted (trending / recently updated,
             whose sort key is not returned in the row), so preserve each file's order and
             round-robin across files. Gives a blended "top of both" without a sort key.
    limit: max rows to emit.

Prints TSV rows to stdout: <display_name>\\t<downloads_fmt>\\t<repo_id>
(display_name = the part after "/"; hidden third column carries the full repo id, matching
the table's existing 3-column contract). Nothing else goes to stdout.
"""
import json
import sys


def fmt_downloads(d):
    if not d:
        return "—"
    if d >= 1_000_000:
        return "%.1fM" % (d / 1_000_000)
    if d >= 1_000:
        return "%dK" % (d // 1_000)
    return str(d)


def load(path):
    try:
        with open(path) as handle:
            data = json.load(handle)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: hf_models_query.py <order> <limit> <json_file>...\n")
        return 2
    order = argv[1]
    try:
        limit = int(argv[2])
    except ValueError:
        limit = 50
    files = argv[3:]

    lists = [load(p) for p in files]
    best = {}   # repo id -> max downloads seen

    def note(model):
        rid = model.get("id")
        if not rid:
            return None
        dl = model.get("downloads") or 0
        if rid not in best or dl > best[rid]:
            best[rid] = dl
        return rid

    if order == "downloads":
        for models in lists:
            for m in models:
                note(m)
        ordered = sorted(best.keys(), key=lambda rid: -best[rid])
    else:
        # rank: round-robin across the (already API-sorted) files, first occurrence wins.
        ordered = []
        seen = set()
        depth = max((len(m) for m in lists), default=0)
        for i in range(depth):
            for models in lists:
                if i < len(models):
                    rid = note(models[i])
                    if rid and rid not in seen:
                        seen.add(rid)
                        ordered.append(rid)

    for rid in ordered[:limit]:
        name = rid.split("/")[-1]
        sys.stdout.write("%s\t%s\t%s\n" % (name, fmt_downloads(best[rid]), rid))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
