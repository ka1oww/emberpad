"""Tests for scripts/stress_summary.py, on manifests shaped as xcresulttool writes them.

    python3 -I scripts/test_stress_summary.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stress_summary", os.path.join(HERE, "stress_summary.py"))
stress_summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress_summary)


def attachment(name, exported):
    return {"configurationName": "Test Scheme Action", "deviceId": "00000000-0000000000000000",
            "deviceName": "Synthetic iPad", "exportedFileName": exported, "isAssociatedWithFailure": False,
            "suggestedHumanReadableName": name, "timestamp": 1794795690.049}


def test_entry(name, attachments):
    return {"testIdentifier": "DeviceDrawingStressTests/%s()" % name,
            "testIdentifierURL": "test://com.apple.xcode/EmberPad/EmberPadTests/DeviceDrawingStressTests/" + name,
            "attachments": attachments}


# What a device run exports (Xcode 26): the test named its attachments "stress-summary.json" and
# "stress-summary.md"; xcresulttool works a counter and a UUID into each name, and exports the Markdown as .txt.
DEVICE_RUN = [
    test_entry("test01_SamplerSelfCheck", [
        attachment("sampler-page_0_76C75885-5160-4F88-8DFA-313C2BE7DE67.png", "A3088720-0F22-4D59-BBDF-51299AEFF5C9.png"),
    ]),
    {"testIdentifier": "DeviceDrawingStressTests/test18_RapidToolSwitches()"},
    test_entry("test22_AfterPageChange", [
        attachment("afterPageChange-layers-2_0_37D8CC12-7B30-4AB0-9BC7-E9E39BA77298.txt", "BCB74FF0-186D-42F1-A9FE-8D5D1530F607.txt"),
    ]),
    test_entry("test99_Summary", [
        attachment("stress-summary_0_E489C44A-6273-4D19-8A3B-79A53ED1D89E.md", "C4871D25-994A-4BF1-9329-F61C95821EA0.txt"),
        attachment("stress-summary_0_6AEC0802-8089-4CB3-BDF8-965D6553F5E2.json", "85CD6E98-BBA1-455E-91A7-9A6C7D33FC9E.json"),
    ]),
]

SUMMARY_JSON = json.dumps({"schema": "emberpad.device-stress/1", "passed": True})
SUMMARY_MD = "# Stress test\n\nEvery check passed.\n"


class StressSummaryTests(unittest.TestCase):
    def output(self, manifest, files):
        """An output folder as the script leaves it after exporting: attachments/ with `manifest` and `files`."""
        out = tempfile.mkdtemp(prefix="stress-summary-test-")
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", out], check=False))
        os.mkdir(os.path.join(out, "attachments"))
        if manifest is not None:
            with open(os.path.join(out, "attachments", "manifest.json"), "w") as file:
                json.dump(manifest, file)
        for name, text in files.items():
            with open(os.path.join(out, "attachments", name), "w") as file:
                file.write(text)
        return out

    def read(self, out, name):
        with open(os.path.join(out, name)) as file:
            return file.read()

    def test_the_summary_is_found_under_the_names_xcresulttool_gives_it(self):
        out = self.output(DEVICE_RUN, {
            "A3088720-0F22-4D59-BBDF-51299AEFF5C9.png": "picture",
            "BCB74FF0-186D-42F1-A9FE-8D5D1530F607.txt": "layers",
            "C4871D25-994A-4BF1-9329-F61C95821EA0.txt": SUMMARY_MD,
            "85CD6E98-BBA1-455E-91A7-9A6C7D33FC9E.json": SUMMARY_JSON,
        })
        self.assertEqual(sorted(stress_summary.copy_summaries(out)), ["json", "md"])
        self.assertEqual(self.read(out, "summary.json"), SUMMARY_JSON)
        self.assertEqual(self.read(out, "summary.md"), SUMMARY_MD)

    def test_the_summary_is_found_under_the_names_the_test_gave_it(self):
        manifest = [test_entry("test99_Summary", [attachment("stress-summary.json", "one.json"),
                                                  attachment("stress-summary.md", "two.txt")])]
        out = self.output(manifest, {"one.json": SUMMARY_JSON, "two.txt": SUMMARY_MD})
        self.assertEqual(sorted(stress_summary.copy_summaries(out)), ["json", "md"])
        self.assertEqual(self.read(out, "summary.json"), SUMMARY_JSON)
        self.assertEqual(self.read(out, "summary.md"), SUMMARY_MD)

    def test_a_run_that_attached_no_summary_copies_none(self):
        stopped_early = DEVICE_RUN[:3]
        out = self.output(stopped_early, {
            "A3088720-0F22-4D59-BBDF-51299AEFF5C9.png": "picture",
            "BCB74FF0-186D-42F1-A9FE-8D5D1530F607.txt": "layers",
        })
        self.assertEqual(stress_summary.copy_summaries(out), [])
        self.assertFalse(os.path.exists(os.path.join(out, "summary.json")))
        self.assertFalse(os.path.exists(os.path.join(out, "summary.md")))

    def test_a_missing_or_unreadable_manifest_copies_none(self):
        self.assertEqual(stress_summary.copy_summaries(self.output(None, {})), [])
        out = self.output(None, {"manifest.json": "not json"})
        self.assertEqual(stress_summary.copy_summaries(out), [])
        self.assertEqual(stress_summary.copy_summaries(os.path.join(out, "no such folder")), [])

    def test_only_the_summarys_own_names_count(self):
        for name, kind in [
            ("stress-summary.json", "json"),
            ("stress-summary.md", "md"),
            ("stress-summary_0_6AEC0802-8089-4CB3-BDF8-965D6553F5E2.json", "json"),
            ("stress-summary_12_E489C44A-6273-4D19-8A3B-79A53ED1D89E.md", "md"),
            ("stress-summary_0_6AEC0802-8089-4CB3-BDF8-965D6553F5E2.txt", None),
            ("stress-summary.png", None),
            ("stress-summary", None),
            ("stress-summaryjson", None),
            ("stress-summary (1).json", "json"),
            ("pre-stress-summary.json", None),
            ("afterPageChange-layers-2_0_37D8CC12-7B30-4AB0-9BC7-E9E39BA77298.txt", None),
            ("", None),
        ]:
            self.assertEqual(stress_summary.summary_kind(name), kind, name)

    def test_a_listed_summary_whose_file_was_not_exported_copies_none(self):
        out = self.output(DEVICE_RUN, {})
        self.assertEqual(stress_summary.copy_summaries(out), [])
        self.assertFalse(os.path.exists(os.path.join(out, "summary.json")))

    def test_run_as_the_stress_script_runs_it(self):
        out = self.output(DEVICE_RUN, {
            "C4871D25-994A-4BF1-9329-F61C95821EA0.txt": SUMMARY_MD,
            "85CD6E98-BBA1-455E-91A7-9A6C7D33FC9E.json": SUMMARY_JSON,
        })
        script = os.path.join(HERE, "stress_summary.py")
        done = subprocess.run([sys.executable, "-I", script, out], capture_output=True, text=True, check=True)
        self.assertEqual(sorted(done.stdout.split()), ["json", "md"])
        self.assertEqual(self.read(out, "summary.json"), SUMMARY_JSON)


if __name__ == "__main__":
    unittest.main()
