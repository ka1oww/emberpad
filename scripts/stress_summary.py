"""Copies the stress test's summary out of the attachments xcresulttool exported.

    python3 -I scripts/stress_summary.py <output-dir>

The last stress test attaches its summary twice, as "stress-summary.json" and "stress-summary.md".
xcresulttool exports every attachment under a name of its own and lists them in
<output-dir>/attachments/manifest.json, where the name the test gave comes back with a counter and a
UUID worked in before the extension: "stress-summary_0_<UUID>.json". This copies the two to
<output-dir>/summary.json and <output-dir>/summary.md, and prints the kinds it copied.
"""
import json
import os
import shutil
import sys

SUMMARY_STEM = "stress-summary"
SUMMARY_KINDS = ("json", "md")


def summary_kind(name):
    """The kind of summary ("json" or "md") an attachment called `name` is, or None when it is not one.

    The name is the test's own ("stress-summary.json") or xcresulttool's form of it
    ("stress-summary_0_<UUID>.json"): the stem begins with the summary's name and the extension is its kind.
    """
    stem, extension = os.path.splitext(name)
    kind = extension[1:]
    if kind not in SUMMARY_KINDS:
        return None
    return kind if stem.startswith(SUMMARY_STEM) else None


def copy_summaries(out):
    """Copies each attached summary to `out`/summary.<kind>; returns the kinds copied, in order, without repeats."""
    folder = os.path.join(out, "attachments")
    try:
        with open(os.path.join(folder, "manifest.json")) as file:
            manifest = json.load(file)
    except (OSError, ValueError):
        return []
    copied = []
    for test in manifest if isinstance(manifest, list) else []:
        for item in test.get("attachments", []):
            kind = summary_kind(item.get("suggestedHumanReadableName", ""))
            exported = item.get("exportedFileName")
            if kind is None or not exported:
                continue
            source = os.path.join(folder, exported)
            if not os.path.isfile(source):
                continue
            shutil.copyfile(source, os.path.join(out, "summary." + kind))
            if kind not in copied:
                copied.append(kind)
    return copied


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: stress_summary.py <output-dir>")
    print(" ".join(copy_summaries(sys.argv[1])))
