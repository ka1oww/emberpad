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
                  "    + 2996 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8\n\n"
                  "Sort by top of stack, same collapsed (when >= 5):\n        semaphore_wait_trap        2996\n\n"
                  "Binary Images:\n       0x1 - 0x2 EmberPad\n")
        graph = report.call_graph(sample)
        self.assertEqual(graph.splitlines()[:3], [
            "Call graph: 1 threads, 1 different stacks",
            "    1 thread: Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)",
            "    + 2996 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8"])
        self.assertTrue(graph.endswith("semaphore_wait_trap        2996"), graph)
        self.assertNotIn("Binary Images", graph)
        self.assertNotIn("Analysis of sampling", graph)

    def test_threads_stuck_in_the_same_place_are_printed_once_with_their_count_and_names(self):
        def thread(number, count, queue, top):
            return ("    %d Thread_%d   DispatchQueue_%d: %s\n"
                    "    + %d _pthread_wqthread  (in libsystem_pthread.dylib) + 288  [0x10]\n"
                    "    +   %d %s\n" % (count, number, number, queue, count, count, top))
        waiting = "_dispatch_sema4_wait  (in libdispatch.dylib) + 28  [0x20]"
        sample = ("Call graph:\n"
                  + thread(9, 2467, "com.apple.main-thread  (serial)", "dispatch_group_wait  (in libdispatch.dylib)")
                  + thread(10, 2467, "formFillingQueue  (serial)", waiting)
                  + thread(11, 2460, "formFillingQueue  (serial)", waiting)
                  + thread(12, 2466, "VNRecognizeDocumentsRequestRevision1", waiting)
                  + thread(13, 2465, "other  (serial)", "__workq_kernreturn  (in libsystem_kernel.dylib) + 8")
                  + "\nBinary Images:\n")
        lines = report.call_graph(sample).splitlines()
        self.assertEqual(lines[0], "Call graph: 5 threads, 3 different stacks")
        self.assertEqual(lines[1], "    1 thread: Thread_9   DispatchQueue_9: com.apple.main-thread  (serial)")
        self.assertEqual(lines[4], "    3 threads: Thread_10   DispatchQueue_10: formFillingQueue  (serial); "
                                   "Thread_11   DispatchQueue_11: formFillingQueue  (serial); "
                                   "Thread_12   DispatchQueue_12: VNRecognizeDocumentsRequestRevision1")
        self.assertEqual(lines[5:7], ["    + 2467 _pthread_wqthread  (in libsystem_pthread.dylib) + 288  [0x10]",
                                      "    +   2467 " + waiting])
        self.assertEqual(lines[7], "    1 thread: Thread_13   DispatchQueue_13: other  (serial)")
        self.assertEqual(len(lines), 10)

    def test_a_very_long_call_graph_is_printed_whole(self):
        sample = "Call graph:\n    1 Thread_1   main\n" + "".join("    + 1 frame %d\n" % n for n in range(3000))
        lines = report.call_graph(sample).splitlines()
        self.assertEqual(len(lines), 3002)
        self.assertEqual(lines[-1], "    + 1 frame 2999")

    def test_a_sample_with_nothing_in_it_gives_nothing(self):
        self.assertEqual(report.call_graph(""), "")


if __name__ == "__main__":
    unittest.main()
