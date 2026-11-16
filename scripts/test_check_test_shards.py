"""Tests for scripts/check_test_shards.py.

    python3 -I scripts/test_check_test_shards.py
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check_test_shards", os.path.join(HERE, "check_test_shards.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

CLASSES = {"EmberPadTests/AlphaTests", "EmberPadTests/BetaTests", "EmberPadTests/GammaTests",
           "EmberPadTests/DeviceDrawingStressTests", "EmberPadUITests/DragUITests", "EmberPadUITests/TabsUITests"}


def workflow(one, two, three):
    """A workflow shaped as build.yml is, with these selections for shards 1, 2 and 3."""
    def block(shard, picks):
        return "          - shard: %d\n            selection: >-\n%s" % (
            shard, "".join("              %s\n" % pick for pick in picks))
    return ("jobs:\n  ipad-tests:\n    strategy:\n      matrix:\n        include:\n"
            + block(1, one) + block(2, two) + block(3, three)
            + "    env:\n      NOT_A_SELECTION: -only-testing:EmberPadTests/Ignored\n")


GOOD = workflow(["-only-testing:EmberPadTests/AlphaTests"],
                ["-only-testing:EmberPadUITests/DragUITests"],
                ["-skip-testing:EmberPadTests/AlphaTests", "-skip-testing:EmberPadUITests/DragUITests",
                 "-skip-testing:EmberPadTests/DeviceDrawingStressTests"])


class CheckTestShardsTests(unittest.TestCase):
    def problems(self, text):
        return check.problems(check.shards(text), CLASSES)

    def test_the_shards_are_read_with_their_selections_and_nothing_after_them(self):
        self.assertEqual(check.shards(GOOD), {
            "1": [("only", "EmberPadTests/AlphaTests")],
            "2": [("only", "EmberPadUITests/DragUITests")],
            "3": [("skip", "EmberPadTests/AlphaTests"), ("skip", "EmberPadUITests/DragUITests"),
                  ("skip", "EmberPadTests/DeviceDrawingStressTests")],
        })

    def test_every_class_in_exactly_one_shard_passes(self):
        self.assertEqual(self.problems(GOOD), [])
        self.assertEqual(check.layout(check.shards(GOOD), CLASSES), {
            "1": ["EmberPadTests/AlphaTests"],
            "2": ["EmberPadUITests/DragUITests"],
            "3": ["EmberPadTests/BetaTests", "EmberPadTests/GammaTests", "EmberPadUITests/TabsUITests"],
        })

    def test_a_class_named_in_a_shard_but_not_skipped_would_run_twice(self):
        text = GOOD.replace("              -skip-testing:EmberPadUITests/DragUITests\n", "")
        self.assertEqual(self.problems(text), ["EmberPadUITests/DragUITests runs twice: shard 3 must skip it"])

    def test_a_class_skipped_but_named_nowhere_would_never_run(self):
        text = GOOD.replace("-skip-testing:EmberPadTests/AlphaTests", "-skip-testing:EmberPadTests/AlphaTests\n"
                            "              -skip-testing:EmberPadTests/BetaTests")
        self.assertEqual(self.problems(text),
                         ["EmberPadTests/BetaTests runs nowhere: shard 3 skips it and no other shard names it"])

    def test_the_device_stress_tests_must_stay_skipped(self):
        text = GOOD.replace("              -skip-testing:EmberPadTests/DeviceDrawingStressTests\n", "")
        self.assertEqual(self.problems(text),
                         ["EmberPadTests/DeviceDrawingStressTests runs twice: shard 3 must skip it"])

    def test_a_class_named_in_two_shards_is_reported(self):
        text = GOOD.replace("-only-testing:EmberPadUITests/DragUITests", "-only-testing:EmberPadTests/AlphaTests")
        self.assertIn("EmberPadTests/AlphaTests is named in shard 1 and in shard 2", self.problems(text))

    def test_a_name_that_is_not_a_test_class_is_reported(self):
        text = GOOD.replace("EmberPadTests/AlphaTests", "EmberPadTests/AlphaTest")
        self.assertEqual(self.problems(text), ["EmberPadTests/AlphaTest is named in the workflow but is not a test class"])

    def test_there_must_be_one_shard_that_runs_the_rest(self):
        none = workflow(["-only-testing:EmberPadTests/AlphaTests"], ["-only-testing:EmberPadTests/BetaTests"],
                        ["-only-testing:EmberPadTests/GammaTests"])
        self.assertEqual(len(self.problems(none)), 1)
        self.assertIn("exactly one shard must only skip classes", self.problems(none)[0])

    def test_a_shard_that_selects_nothing_is_reported(self):
        text = workflow([], ["-only-testing:EmberPadTests/AlphaTests"],
                        ["-skip-testing:EmberPadTests/AlphaTests", "-skip-testing:EmberPadTests/DeviceDrawingStressTests"])
        self.assertEqual(self.problems(text), ["shard 1 selects nothing, so it would run every test"])

    def test_this_repository_runs_every_test_class_exactly_once(self):
        root = os.path.dirname(HERE)
        with open(os.path.join(root, ".github", "workflows", "build.yml"), encoding="utf-8") as file:
            found = check.shards(file.read())
        classes = check.test_classes(root)
        self.assertEqual(check.problems(found, classes), [])
        runs = check.layout(found, classes)
        ran = [test for tests in runs.values() for test in tests]
        self.assertEqual(sorted(ran), sorted(classes - check.NEVER_IN_CI))


if __name__ == "__main__":
    unittest.main()
