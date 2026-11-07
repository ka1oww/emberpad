#!/usr/bin/env python3
"""Pure file-format helpers for renew.zsh. No device or account operations."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile


def read_state(path):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".renew-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def expiry_epoch(path):
    with Path(path).open("rb") as source:
        value = plistlib.load(source).get("ExpirationDate")
    if not isinstance(value, datetime):
        raise ValueError("Provisioning profile has no valid ExpirationDate")
    return int(value.replace(tzinfo=timezone.utc).timestamp())


def values_for_key(value, name):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == name:
                yield child
            yield from values_for_key(child, name)
    elif isinstance(value, list):
        for child in value:
            yield from values_for_key(child, name)


def unique_value(value, key):
    found = list(values_for_key(value, key))
    if not found or any(item != found[0] for item in found):
        raise ValueError(f"Missing or conflicting {key}; inspect this Xcode's JSON during setup")
    return found[0]


def readiness(devices, details, lock, device_id):
    # Select one exact device before looking for properties. Never fall back to the first paired device.
    candidates = devices.get("result", {}).get("devices", [])
    selected = [item for item in candidates if any(
        candidate == device_id for key in ("identifier", "udid") for candidate in values_for_key(item, key)
    )]
    if len(selected) != 1:
        raise ValueError("Configured iPad is unavailable or ambiguous")
    tunnel = unique_value(selected[0], "tunnelState")
    if tunnel not in ("connected", "disconnected"):
        raise ValueError("Configured iPad is unreachable; retry on home Wi-Fi")
    if unique_value(selected[0], "pairingState") != "paired":
        raise ValueError("Configured iPad needs the supervised cable setup")
    result = details.get("result", {})
    if unique_value(result, "ddiServicesAvailable") is not True:
        raise ValueError("Unlock the iPad once near the Mac after its restart/update")
    if unique_value(result, "developerModeStatus") != "enabled":
        raise ValueError("Developer Mode needs the supervised one-time setup")
    locked = unique_value(lock.get("result", {}), "passcodeRequired")
    if not isinstance(locked, bool):
        raise ValueError("Unrecognized lock-state JSON; inspect it during setup")
    # A locked screen is allowed only with the DDI already mounted. This never launches the app.
    return "ready-locked" if locked else "ready"


def outbox_check(folder):
    """Checks a copied Companion Outbox before delivery: EmberLibrary/manifest.json must be a version-2 manifest,
    and every PDF it lists that is present under EmberLibrary/files/ must match its size and SHA-256. Unlisted or
    non-PDF entries are refused. Listed PDFs may be absent (copies carried forward without bytes): the iPad
    checks every file again and keeps its own copy. Prints "<entries> <present> <absent>"."""
    library = Path(folder) / "EmberLibrary"
    manifest_path = library / "manifest.json"
    if library.is_symlink() or not library.is_dir() or manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("Outbox has no EmberLibrary/manifest.json; prepare the iPad library in the Companion")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or manifest.get("version") != 2 or not isinstance(manifest.get("files"), list):
        raise ValueError("Outbox manifest is not a version-2 manifest")
    entries = manifest["files"]
    expected = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Outbox manifest has an invalid entry")
        digest, size = entry.get("sha256"), entry.get("size")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or not isinstance(size, int):
            raise ValueError("Outbox manifest has an invalid entry")
        if expected.get(digest, size) != size:
            raise ValueError("Outbox manifest lists one hash with two sizes")
        expected[digest] = size
    files = library / "files"
    present = 0
    if files.exists():
        if files.is_symlink() or not files.is_dir():
            raise ValueError("Outbox files folder is not a folder")
        for item in files.iterdir():
            digest = item.name[:-4] if item.name.endswith(".pdf") else None
            if digest not in expected or item.is_symlink() or not item.is_file():
                raise ValueError(f"Outbox holds an unlisted file: {item.name}")
            hasher = hashlib.sha256()
            with item.open("rb") as source:
                for block in iter(lambda: source.read(1 << 20), b""):
                    hasher.update(block)
            if item.stat().st_size != expected[digest] or hasher.hexdigest() != digest:
                raise ValueError(f"Outbox file does not match its manifest hash: {item.name}")
            present += 1
    return f"{len(entries)} {present} {len(expected) - present}"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    expiry = sub.add_parser("expiry")
    expiry.add_argument("plist")
    for name in ("due", "seconds-left"):
        command = sub.add_parser(name)
        command.add_argument("state")
    record = sub.add_parser("record-install")
    record.add_argument("state")
    record.add_argument("expiry", type=int)
    record.add_argument("bundle_id")
    setting = sub.add_parser("bundle-id")
    setting.add_argument("xcconfig")
    ready = sub.add_parser("readiness")
    ready.add_argument("devices")
    ready.add_argument("details")
    ready.add_argument("lock")
    ready.add_argument("device_id")
    outbox = sub.add_parser("outbox-check")
    outbox.add_argument("folder")
    args = parser.parse_args()
    now = int(datetime.now(timezone.utc).timestamp())
    if args.command == "expiry":
        print(expiry_epoch(args.plist))
    elif args.command in ("due", "seconds-left"):
        state = read_state(args.state)
        expiry_value = state.get("expires")
        seconds = expiry_value - now if isinstance(expiry_value, int) else -1
        print(("due" if seconds < 4 * 86400 else "not-due") if args.command == "due" else seconds)
    elif args.command == "record-install":
        atomic_json(args.state, {"lastInstall": now, "expires": args.expiry, "bundleID": args.bundle_id, "result": "installed"})
    elif args.command == "bundle-id":
        matches = re.findall(r"^EMBERPAD_BUNDLE_ID\s*=\s*([A-Za-z0-9.-]+)\s*$", Path(args.xcconfig).read_text(), re.MULTILINE)
        if len(matches) != 1 or matches[0] == "dev.emberpad.placeholder" or "." not in matches[0]:
            raise ValueError("Approve and set one final EMBERPAD_BUNDLE_ID in Config/Shared.xcconfig first")
        print(matches[0])
    elif args.command == "readiness":
        inputs = [json.loads(Path(path).read_text()) for path in (args.devices, args.details, args.lock)]
        print(readiness(*inputs, args.device_id))
    elif args.command == "outbox-check":
        print(outbox_check(args.folder))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(str(error))
