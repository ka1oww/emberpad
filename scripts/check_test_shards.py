"""Checks that the workflow's iPad test shards run every test class exactly once.

    python3 -I scripts/check_test_shards.py

.github/workflows/build.yml splits the iPad tests over parallel shards. Each shard but one names its test
classes with -only-testing; the remaining shard skips exactly those classes with -skip-testing, so it runs
everything else, including a class added later. This reads the shards and the test classes in the two test
folders and fails when a named class does not exist (a renamed class would silently run nowhere, or twice),
when a class is named in two shards, or when the skip list is not exactly the classes the other shards name
plus the classes that never run in CI.
"""
import os
import re
import sys

TARGETS = ("EmberPadTests", "EmberPadUITests")
# Run only from scripts/device-stress-test.sh and scripts/device-present-latency.sh.
NEVER_IN_CI = {"EmberPadTests/DeviceDrawingStressTests", "EmberPadTests/DevicePresentLatencyTests"}

SHARD = re.compile(r"^\s*-\s+shard:\s*(\S+)\s*$")
SELECTION = re.compile(r"-(only|skip)-testing:(\S+)")
TEST_CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.MULTILINE)


def shards(workflow):
    """Each shard's selection, in order: {shard: [("only" or "skip", "Target/Class"), ...]}."""
    found = {}
    current = None
    for line in workflow.splitlines():
        start = SHARD.match(line)
        if start:
            current = start.group(1)
            found[current] = []
        elif current is not None:
            if line.strip() and not line.startswith(" " * 12):
                current = None
            else:
                found[current].extend(SELECTION.findall(line))
    return found


def test_classes(root):
    """Every XCTestCase class in the two test folders, as "Target/Class"."""
    classes = set()
    for target in TARGETS:
        for folder, _, files in os.walk(os.path.join(root, "Apps", target)):
            for name in files:
                if name.endswith(".swift"):
                    with open(os.path.join(folder, name), encoding="utf-8") as file:
                        classes.update(target + "/" + found for found in TEST_CLASS.findall(file.read()))
    return classes


def problems(found, classes):
    """What is wrong with the shards `found` for the test classes `classes`; empty when each class runs once."""
    wrong = []
    catch_all = [shard for shard, picks in found.items() if picks and all(kind == "skip" for kind, _ in picks)]
    if len(catch_all) != 1:
        return ["exactly one shard must only skip classes, so it runs every class the others do not name; "
                "found %d (%s)" % (len(catch_all), ", ".join(catch_all) or "none")]
    named = {}
    for shard, picks in found.items():
        if shard == catch_all[0]:
            continue
        if not picks:
            wrong.append("shard %s selects nothing, so it would run every test" % shard)
        for kind, test in picks:
            if kind != "only":
                wrong.append("shard %s mixes -skip-testing:%s with -only-testing" % (shard, test))
            elif test in named:
                wrong.append("%s is named in shard %s and in shard %s" % (test, named[test], shard))
            else:
                named[test] = shard
    skipped = [test for _, test in found[catch_all[0]]]
    for test in sorted(set(named) | set(skipped)):
        if test not in classes:
            wrong.append("%s is named in the workflow but is not a test class" % test)
    for test in sorted(set(skipped)):
        if skipped.count(test) > 1:
            wrong.append("shard %s skips %s twice" % (catch_all[0], test))
    expected = set(named) | NEVER_IN_CI
    for test in sorted(expected - set(skipped)):
        wrong.append("%s runs twice: shard %s must skip it" % (test, catch_all[0]))
    for test in sorted(set(skipped) - expected):
        wrong.append("%s runs nowhere: shard %s skips it and no other shard names it" % (test, catch_all[0]))
    return wrong


def layout(found, classes):
    """Which classes each shard runs, for the log: {shard: sorted classes}."""
    catch_all = next(shard for shard, picks in found.items() if picks and all(kind == "skip" for kind, _ in picks))
    skipped = {test for _, test in found[catch_all]}
    return {shard: sorted(classes - skipped) if shard == catch_all else sorted(test for _, test in picks)
            for shard, picks in found.items()}


def main(root):
    with open(os.path.join(root, ".github", "workflows", "build.yml"), encoding="utf-8") as file:
        found = shards(file.read())
    classes = test_classes(root)
    wrong = problems(found, classes)
    if wrong:
        print("The iPad test shards in .github/workflows/build.yml do not run every test class exactly once:")
        for line in wrong:
            print("  " + line)
        return 1
    runs = layout(found, classes)
    for shard, tests in runs.items():
        print("shard %s runs %d classes" % (shard, len(tests)))
    total = sum(len(tests) for tests in runs.values())
    print("%d test classes, each in exactly one shard; %d never run in CI (%s)"
          % (total, len(NEVER_IN_CI), ", ".join(sorted(NEVER_IN_CI))))
    return 0


if __name__ == "__main__":
    sys.exit(main(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
