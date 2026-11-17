"""Tests for scripts/report_hung_test.py.

    python3 -I scripts/test_report_hung_test.py
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("report_hung_test", os.path.join(HERE, "report_hung_test.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

ONE = "-[EmberPadTests.StudentBackdropTests testClearingRemovesTheBackdropAndClearingNothingIsFine]"
TWO = "-[EmberPadTests.StudentBackdropTests testIdleShowsTheBackdropAloneWithNoStarOrText]"
# As xcodebuild writes them in CI, with the runner's time stamps in front.
HUNG = ("2026-11-16T22:50:48.6Z Test Case '%s' started.\n"
        "2026-11-16T22:50:48.7Z Test Case '%s' passed (0.042 seconds).\n"
        "2026-11-16T22:50:48.7Z Test Case '%s' started.\n" % (ONE, ONE, TWO))


class ReportHungTestTests(unittest.TestCase):
    def test_the_test_that_started_and_has_not_ended_is_the_one_running(self):
        self.assertEqual(report.running_test(HUNG), TWO)

    def test_no_test_is_running_before_the_first_starts_or_once_the_last_has_ended(self):
        self.assertIsNone(report.running_test("Build succeeded\n"))
        for ending in ("passed (9.918 seconds).", "failed (3.100 seconds).", "skipped (0.001 seconds).",
                       "exceeded execution time allowance of 5 minutes. The test may have hung;"):
            self.assertIsNone(report.running_test(HUNG + "Test Case '%s' %s\n" % (TWO, ending)), ending)

    def test_a_test_run_again_after_it_passed_is_running_until_that_run_ends_too(self):
        again = HUNG + "Test Case '%s' passed (9.9 seconds).\nTest Case '%s' started.\n" % (TWO, ONE)
        self.assertEqual(report.running_test(again), ONE)
        self.assertIsNone(report.running_test(again + "Test Case '%s' passed (0.04 seconds).\n" % ONE))

    def test_a_running_test_is_due_only_once_quiet_for_long_enough_and_only_once(self):
        self.assertIsNone(report.due(HUNG, report.QUIET - 1, set()))
        self.assertEqual(report.due(HUNG, report.QUIET, set()), TWO)
        self.assertIsNone(report.due(HUNG, report.QUIET * 3, {TWO}))
        self.assertIsNone(report.due("Build succeeded\n", report.QUIET * 3, set()))

    def test_the_call_graph_is_cut_from_the_sample_without_its_header_or_its_list_of_binaries(self):
        sample = ("Analysis of sampling EmberPad (pid 1) every 1 millisecond\nPath: /x/EmberPad\n----\n\n"
                  "Call graph:\n    2996 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n"
                  "      2996 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8\n\n"
                  "Sort by top of stack, same collapsed (when >= 5):\n        semaphore_wait_trap        2996\n\n"
                  "Binary Images:\n       0x1 - 0x2 EmberPad\n")
        graph = report.call_graph(sample)
        self.assertTrue(graph.startswith("Call graph:\n    2996 Thread_1"), graph)
        self.assertTrue(graph.endswith("semaphore_wait_trap        2996"), graph)
        self.assertNotIn("Binary Images", graph)
        self.assertNotIn("Analysis of sampling", graph)

    def test_a_very_long_call_graph_is_cut_short_and_says_so(self):
        sample = "Call graph:\n" + "".join("    1 frame %d\n" % n for n in range(report.MOST_LINES + 40))
        lines = report.call_graph(sample).splitlines()
        self.assertEqual(len(lines), report.MOST_LINES + 1)
        self.assertEqual(lines[-1], "... 41 more lines")

    def test_a_sample_with_nothing_in_it_gives_nothing(self):
        self.assertEqual(report.call_graph(""), "")


if __name__ == "__main__":
    unittest.main()
