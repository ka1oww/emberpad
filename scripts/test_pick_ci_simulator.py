"""Tests for scripts/pick_ci_simulator.py.

    python3 -I scripts/test_pick_ci_simulator.py
"""
import importlib.util
import io
import json
import os
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("pick_ci_simulator", os.path.join(HERE, "pick_ci_simulator.py"))
pick = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pick)

ELEVEN = pick.DEVICE_TYPE
THIRTEEN = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
PHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
TYPES = [{"name": "iPhone 17 Pro", "identifier": PHONE},
         {"name": "iPad Pro 13-inch (M5)", "identifier": THIRTEEN},
         {"name": "iPad Pro 11-inch (M5)", "identifier": ELEVEN}]


def runtime(number, kinds=(PHONE, THIRTEEN, ELEVEN), platform="iOS", available=True):
    return {"name": "%s %s" % (platform, number), "version": number, "platform": platform, "isAvailable": available,
            "identifier": "com.apple.CoreSimulator.SimRuntime.%s-%s" % (platform, number.replace(".", "-")),
            "supportedDeviceTypes": [{"identifier": kind} for kind in kinds]}


def device(udid, kind, available=True):
    return {"udid": udid, "deviceTypeIdentifier": kind, "isAvailable": available, "name": "named anything"}


def on(number, *devices):
    return {"com.apple.CoreSimulator.SimRuntime.iOS-%s" % number.replace(".", "-"): list(devices)}


class PickCISimulatorTests(unittest.TestCase):
    def test_the_11_inch_is_used_though_a_13_inch_is_listed_first(self):
        devices = on("26.5", device("THIRTEEN", THIRTEEN), device("PHONE", PHONE), device("ELEVEN", ELEVEN))
        self.assertEqual(pick.choose(devices, TYPES, [runtime("26.5")]), ("use", "ELEVEN", "iOS 26.5"))

    def test_the_newest_ios_runtime_is_used_whatever_order_they_are_listed_in(self):
        devices = {**on("26.4.1", device("OLD", ELEVEN)), **on("26.10", device("NEW", ELEVEN)),
                   **on("26.9", device("MIDDLE", ELEVEN))}
        runtimes = [runtime("26.4.1"), runtime("26.10"), runtime("26.9"), runtime("27.0", platform="tvOS")]
        self.assertEqual(pick.choose(devices, TYPES, runtimes), ("use", "NEW", "iOS 26.10"))

    def test_one_is_created_on_the_newest_runtime_when_that_runtime_has_none(self):
        devices = {**on("26.4.1", device("OLD", ELEVEN)), **on("26.5", device("THIRTEEN", THIRTEEN))}
        self.assertEqual(pick.choose(devices, TYPES, [runtime("26.4.1"), runtime("26.5")]),
                         ("create", "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "iOS 26.5"))

    def test_a_device_that_cannot_be_booted_is_not_used(self):
        devices = on("26.5", device("BROKEN", ELEVEN, available=False))
        self.assertEqual(pick.choose(devices, TYPES, [runtime("26.5")])[0], "create")

    def test_a_runtime_that_is_not_installed_or_cannot_run_the_11_inch_is_passed_over(self):
        devices = on("26.4.1", device("ELEVEN", ELEVEN))
        runtimes = [runtime("26.4.1"), runtime("26.5", available=False), runtime("26.6", kinds=(PHONE, THIRTEEN))]
        self.assertEqual(pick.choose(devices, TYPES, runtimes), ("use", "ELEVEN", "iOS 26.4.1"))

    def test_a_missing_device_type_fails_and_names_the_ipads_there_are(self):
        devices = on("26.5", device("THIRTEEN", THIRTEEN))
        with self.assertRaises(pick.Missing) as failure:
            pick.choose(devices, TYPES[:2], [runtime("26.5", kinds=(PHONE, THIRTEEN))])
        self.assertIn("no iPad Pro 11-inch (M5) device type", str(failure.exception))
        self.assertIn("iPad device types it has: iPad Pro 13-inch (M5)", str(failure.exception))

    def test_no_ios_runtime_for_it_fails_and_names_the_runtimes_there_are(self):
        devices = on("26.5", device("THIRTEEN", THIRTEEN))
        runtimes = [runtime("26.5", kinds=(PHONE, THIRTEEN)), runtime("26.5", platform="tvOS")]
        with self.assertRaises(pick.Missing) as failure:
            pick.choose(devices, TYPES, runtimes)
        self.assertIn("no installed iOS runtime can run the iPad Pro 11-inch (M5)", str(failure.exception))
        self.assertIn("Runtimes installed: iOS 26.5, tvOS 26.5", str(failure.exception))

    def test_no_runtime_at_all_fails(self):
        with self.assertRaises(pick.Missing):
            pick.choose({}, TYPES, [])


class Simctl:
    """Stands in for `xcrun simctl`: answers the three listings and records every call."""

    def __init__(self, devices, runtimes, types=TYPES, create="CREATED\n"):
        self.answers = {"devices": {"devices": devices}, "devicetypes": {"devicetypes": types},
                        "runtimes": {"runtimes": runtimes}}
        self.create = create
        self.calls = []

    def __call__(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "list":
            return json.dumps(self.answers[arguments[1]])
        if isinstance(self.create, Exception):
            raise self.create
        return self.create


class PickCISimulatorRunTests(unittest.TestCase):
    def run_with(self, simctl):
        out, log = io.StringIO(), io.StringIO()
        return pick.main(simctl, out, log), out.getvalue(), log.getvalue(), simctl.calls

    def test_the_installed_11_inch_is_printed_alone_and_nothing_is_created(self):
        simctl = Simctl(on("26.5", device("THIRTEEN", THIRTEEN), device("ELEVEN", ELEVEN)), [runtime("26.5")])
        code, out, log, calls = self.run_with(simctl)
        self.assertEqual((code, out), (0, "ELEVEN\n"))
        self.assertEqual(log, "iPad Pro 11-inch (M5) on iOS 26.5 (as installed): ELEVEN\n")
        self.assertEqual([call[0] for call in calls], ["list", "list", "list"])

    def test_one_is_created_by_device_type_on_the_newest_runtime_and_printed(self):
        simctl = Simctl(on("26.5", device("THIRTEEN", THIRTEEN)), [runtime("26.4.1"), runtime("26.5")])
        code, out, log, calls = self.run_with(simctl)
        self.assertEqual((code, out), (0, "CREATED\n"))
        self.assertEqual(calls[-1], ("create", "iPad Pro 11-inch (M5)", ELEVEN,
                                     "com.apple.CoreSimulator.SimRuntime.iOS-26-5"))
        self.assertEqual(log, "iPad Pro 11-inch (M5) on iOS 26.5 (created): CREATED\n")

    def test_with_no_11_inch_to_be_had_it_fails_prints_no_udid_and_names_the_cause_as_the_jobs_error(self):
        simctl = Simctl(on("26.5", device("THIRTEEN", THIRTEEN)), [runtime("26.5", kinds=(PHONE, THIRTEEN))],
                        types=TYPES[:2])
        code, out, log, calls = self.run_with(simctl)
        self.assertEqual((code, out), (1, ""))
        self.assertTrue(log.startswith("::error::this Xcode has no iPad Pro 11-inch (M5) device type"), log)
        self.assertNotIn("create", [call[0] for call in calls])

    def test_a_create_that_fails_fails_the_step_and_prints_no_udid(self):
        failure = subprocess.CalledProcessError(1, ("xcrun", "simctl", "create"), stderr="Invalid runtime\n")
        simctl = Simctl(on("26.5", device("THIRTEEN", THIRTEEN)), [runtime("26.5")], create=failure)
        code, out, log, _ = self.run_with(simctl)
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(log, "::error::simctl create failed, so there is no iPad Pro 11-inch (M5) to test on: "
                              "Invalid runtime\n")


if __name__ == "__main__":
    unittest.main()
