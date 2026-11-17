"""Picks the Simulator the iPad tests run on in CI, and prints its UDID.

    python3 -I scripts/pick_ci_simulator.py

The tests run on an iPad Pro 11-inch (M5), the size nearest the iPad the app is used on, on the newest iOS
runtime installed. How much of a page fits on the screen is part of what some UI tests check (the Teacher copy
names another page on a 13-inch iPad), so the size must not vary with what a runner happens to list first.
This uses that runtime's own device of that type when it has one and creates one when it has not. It never
falls back to another iPad: when the device type or an iOS runtime for it is missing, it fails and says what is
installed.
"""
import json
import subprocess
import sys

DEVICE_NAME = "iPad Pro 11-inch (M5)"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"


class Missing(Exception):
    """The device type, or an iOS runtime that supports it, is not installed."""


def version(runtime):
    """A runtime's version as numbers, so 26.10 sorts after 26.9."""
    return tuple(int(part) for part in runtime["version"].split(".") if part.isdigit())


def supports(runtime):
    """Whether the runtime is an installed iOS runtime that can run the device type."""
    if runtime.get("platform") != "iOS" or not runtime.get("isAvailable"):
        return False
    return any(kind.get("identifier") == DEVICE_TYPE for kind in runtime.get("supportedDeviceTypes", []))


def choose(devices, device_types, runtimes):
    """What to do: ("use", udid, runtime name) or ("create", runtime identifier, runtime name).

    The three arguments are the lists simctl gives for devices (by runtime identifier), device types and
    runtimes. Raises Missing when no simulator of the right size can be had.
    """
    if not any(kind.get("identifier") == DEVICE_TYPE for kind in device_types):
        ipads = sorted(kind["name"] for kind in device_types if kind.get("name", "").startswith("iPad"))
        raise Missing("this Xcode has no %s device type (%s). The iPad tests run on that size only. "
                      "iPad device types it has: %s" % (DEVICE_NAME, DEVICE_TYPE, ", ".join(ipads) or "none"))
    usable = [runtime for runtime in runtimes if supports(runtime)]
    if not usable:
        installed = sorted(runtime["name"] for runtime in runtimes if runtime.get("isAvailable"))
        raise Missing("no installed iOS runtime can run the %s. The iPad tests run on that size only. "
                      "Runtimes installed: %s" % (DEVICE_NAME, ", ".join(installed) or "none"))
    newest = max(usable, key=version)
    for device in devices.get(newest["identifier"], []):
        if device.get("deviceTypeIdentifier") == DEVICE_TYPE and device.get("isAvailable"):
            return ("use", device["udid"], newest["name"])
    return ("create", newest["identifier"], newest["name"])


def simctl(*arguments):
    return subprocess.run(("xcrun", "simctl") + arguments, check=True, capture_output=True, text=True).stdout


def main(simctl=simctl, out=sys.stdout, log=sys.stderr):
    """Prints the UDID to `out`, and what was chosen, or why nothing could be, to `log`."""
    try:
        action, target, runtime = choose(json.loads(simctl("list", "devices", "--json"))["devices"],
                                         json.loads(simctl("list", "devicetypes", "--json"))["devicetypes"],
                                         json.loads(simctl("list", "runtimes", "--json"))["runtimes"])
        udid = simctl("create", DEVICE_NAME, DEVICE_TYPE, target).strip() if action == "create" else target
    except Missing as problem:
        # GitHub shows a line that starts this way as the job's error.
        print("::error::%s" % problem, file=log)
        return 1
    except subprocess.CalledProcessError as failure:
        print("::error::simctl %s failed, so there is no %s to test on: %s"
              % (failure.cmd[2], DEVICE_NAME, (failure.stderr or "").strip()), file=log)
        return 1
    print("%s on %s (%s): %s" % (DEVICE_NAME, runtime, "created" if action == "create" else "as installed", udid),
          file=log)
    print(udid, file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
