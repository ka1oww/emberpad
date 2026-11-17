"""Prints where the app is stuck when a test in CI stops making progress.

    python3 -I scripts/report_hung_test.py <the log xcodebuild is writing> &

xcodebuild fails a test that runs past its time limit and names it, but on a Simulator the stack it saves for the
test is empty ("No samples"), so the log says which test hung and never where. This watches the log while the
tests run. When the test that started last has finished nothing and the log has been quiet for QUIET seconds, it
takes a three-second `sample` of each of the app's processes on the Simulator and prints their call graphs, once
for that test. It changes nothing about the tests: it only reads the log and the processes. It ends when the
shell that started it does.
"""
import os
import re
import subprocess
import sys
import time

# Half the test's time limit in the workflow: long enough that a test still working is rarely caught, and well
# before xcodebuild ends the process.
QUIET = 150
# The app under test, which also hosts the unit tests, and the UI tests' runner.
PROCESSES = ("/EmberPad.app/EmberPad", "/EmberPadUITests-Runner.app/EmberPadUITests-Runner")
MOST_LINES = 500

STARTED = re.compile(r"Test Case '(-\[[^']+\])' started\.")
ENDED = re.compile(r"Test Case '(-\[[^']+\])' (?:passed|failed|skipped|exceeded)")


def running_test(log):
    """The test the log shows started and not ended, or None. Tests run one at a time, so it is the last started,
    unless it has ended as often as it has started (a test can run more than once)."""
    started = STARTED.findall(log)
    if not started or started.count(started[-1]) <= ENDED.findall(log).count(started[-1]):
        return None
    return started[-1]


def call_graph(sample):
    """The part of `sample`'s report that says where each thread is: from "Call graph" to the list of binaries."""
    lines = sample.splitlines()
    start = next((n for n, line in enumerate(lines) if line.startswith("Call graph")), 0)
    end = next((n for n, line in enumerate(lines) if line.startswith("Binary Images")), len(lines))
    graph = lines[start:end]
    if len(graph) > MOST_LINES:
        graph = graph[:MOST_LINES] + ["... %d more lines" % (len(graph) - MOST_LINES)]
    return "\n".join(graph).rstrip()


def due(log, quiet_for, reported):
    """The test to report now: one still running, quiet for long enough, and not reported before."""
    test = running_test(log)
    return test if test and quiet_for >= QUIET and test not in reported else None


def processes():
    """(pid, command) of the app's processes on any Simulator."""
    listing = subprocess.run(("ps", "-axo", "pid=,command="), capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        if "/CoreSimulator/Devices/" in command and any(name in command for name in PROCESSES):
            found.append((pid, command.split(" -")[0]))
    return found


def report(test, quiet_for, out):
    print("\n==== %s has logged nothing for %d s. Where the app is: ====" % (test, quiet_for), file=out)
    found = processes()
    if not found:
        print("none of the app's processes is running on the Simulator", file=out)
    for pid, command in found:
        print("---- pid %s %s" % (pid, command), file=out)
        sample = subprocess.run(("sample", pid, "3"), capture_output=True, text=True)
        print(call_graph(sample.stdout) or "sample gave nothing: %s" % sample.stderr.strip(), file=out)
    print("==== end of the report for %s ====\n" % test, file=out, flush=True)


def main(path):
    parent = os.getppid()
    reported = set()
    while os.getppid() == parent:
        time.sleep(5)
        try:
            quiet_for = time.time() - os.path.getmtime(path)
            with open(path, encoding="utf-8", errors="replace") as file:
                test = due(file.read(), quiet_for, reported)
        except OSError:
            continue
        if test:
            reported.add(test)
            report(test, quiet_for, sys.stdout)


if __name__ == "__main__":
    main(sys.argv[1])
