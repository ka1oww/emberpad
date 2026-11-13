#!/bin/zsh
# Draws on an iPad as fast as a student writes, with every tool, and reports what breaks.
#
#   scripts/device-stress-test.sh <device-udid> <output-dir>
#
# The UDID can be a simulator's or a connected iPad's (`xcrun devicectl list devices`).
# On a physical iPad, set DEVELOPMENT_TEAM to the signing team's ID first; the build passes
# -allowProvisioningUpdates so Xcode can make a profile for the stress-test app.
#
# What it touches. The tests run inside a separate app, "Ember Stress"
# (io.github.ka1oww.emberpad.stresstest), with its own sandbox and Keychain. It is installed
# beside Ember Slate, never over it, and nothing here uninstalls or replaces Ember Slate; the
# script removes only an earlier copy of Ember Stress, so each run starts fresh. Every
# scenario writes into a temporary library of its own; Ember Slate's notebooks are out of reach,
# and the stress app holds no Mac pairing, so it never syncs. The Pencil is synthesized, so
# nobody needs to hold the iPad, but keep it awake and unlocked while it runs.
#
# Output (all in <output-dir>):
#   summary.json      machine-readable results (schema emberpad.device-stress/1)
#   summary.md        the same for a person: each tool's checks, pass or fail, with numbers
#   attachments/      everything the tests attached: evidence pictures and layer dumps
#   commit.txt        the commit the run was built from
#   StressTest.xcresult, xcodebuild.log
# Exit status: 0 when every check passed, 1 when any failed, 2 for a usage or build problem.
set -u

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 <device-udid> <output-dir>"
  exit 2
fi
UDID=$1
OUT=${2:A}
ROOT=${0:A:h:h}
STRESS_BUNDLE_ID=io.github.ka1oww.emberpad.stresstest
PRODUCT_BUNDLE_ID=$(sed -n 's/^EMBERPAD_BUNDLE_ID = //p' "$ROOT/Config/Shared.xcconfig")
DERIVED=${EMBERPAD_STRESS_DERIVED_DATA:-${TMPDIR:-/tmp}/emberpad-device-stress-dd}

if [[ -z $PRODUCT_BUNDLE_ID || $STRESS_BUNDLE_ID == "$PRODUCT_BUNDLE_ID" ]]; then
  print -u2 "refusing: the stress-test app must not share Ember Slate's bundle ID ($PRODUCT_BUNDLE_ID)"
  exit 2
fi

if xcrun simctl list devices --json 2>/dev/null | grep -q "\"udid\" : \"$UDID\""; then
  KIND=simulator
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
  xcrun simctl bootstatus "$UDID" -b >/dev/null || { print -u2 "could not boot simulator $UDID"; exit 2; }
else
  KIND=device
  SIGNING=(-allowProvisioningUpdates)
  if [[ -n ${DEVELOPMENT_TEAM:-} ]]; then
    SIGNING+=(DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM)
  else
    print -u2 "note: DEVELOPMENT_TEAM is not set; signing for a physical iPad usually needs it"
  fi
fi

mkdir -p "$OUT"
rm -rf "$OUT/StressTest.xcresult" "$OUT/attachments" "$OUT/summary.json" "$OUT/summary.md"
print "Stress test on $KIND $UDID as $STRESS_BUNDLE_ID; results in $OUT"
print "commit $(git -C "$ROOT" rev-parse HEAD 2>/dev/null)$( [[ -n $(git -C "$ROOT" status --porcelain 2>/dev/null) ]] && print ' (with uncommitted changes)')" \
  | tee "$OUT/commit.txt"

# Each run starts from a fresh stress app. PencilKit keeps a record of every drawing an app has made, which survives
# relaunches and slows drawing as it grows, so a stress app kept from earlier runs would stall more each time. Only
# the stress app is removed, never Ember Slate: the guard below refuses any other bundle ID.
if [[ $STRESS_BUNDLE_ID == *.stresstest && $STRESS_BUNDLE_ID != "$PRODUCT_BUNDLE_ID" ]]; then
  if [[ $KIND == simulator ]]; then
    xcrun simctl uninstall "$UDID" "$STRESS_BUNDLE_ID" >/dev/null 2>&1
  else
    xcrun devicectl device uninstall app --device "$UDID" "$STRESS_BUNDLE_ID" >/dev/null 2>&1
  fi
fi

# TEST_RUNNER_ variables reach the test process with the prefix removed. EMBERPAD_STRESS=1 is the
# gate: without it, and outside the separate stress-test app, every stress test skips itself.
export TEST_RUNNER_EMBERPAD_STRESS=1
[[ $KIND == simulator ]] && export TEST_RUNNER_EMBERPAD_STRESS_OUTPUT="$OUT"

xcodebuild -project "$ROOT/EmberPad.xcodeproj" -scheme EmberPad -configuration Debug \
  -destination "id=$UDID" -destination-timeout 120 -derivedDataPath "$DERIVED" \
  -resultBundlePath "$OUT/StressTest.xcresult" \
  -only-testing:EmberPadTests/DeviceDrawingStressTests \
  EMBERPAD_BUNDLE_ID=$STRESS_BUNDLE_ID EMBERPAD_DISPLAY_NAME="Ember Stress" ONLY_ACTIVE_ARCH=YES \
  "${SIGNING[@]}" test > "$OUT/xcodebuild.log" 2>&1
STATUS=$?

grep -E "^Test Case .*(passed|failed|skipped)|error: " "$OUT/xcodebuild.log" | cut -c1-300

if [[ ! -d $OUT/StressTest.xcresult ]]; then
  print -u2 "xcodebuild made no result bundle (exit $STATUS); see $OUT/xcodebuild.log"
  tail -20 "$OUT/xcodebuild.log" >&2
  exit 2
fi
xcrun xcresulttool export attachments --path "$OUT/StressTest.xcresult" --output-path "$OUT/attachments" >/dev/null 2>&1

# The summary is attached by the last test; copy it out under predictable names.
python3 -I - "$OUT" <<'EOF'
import json, os, shutil, sys
out = sys.argv[1]
folder = os.path.join(out, "attachments")
try:
    manifest = json.load(open(os.path.join(folder, "manifest.json")))
except Exception:
    manifest = []
for test in manifest:
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        for kind in ("json", "md"):
            if name.startswith("stress-summary." + kind):
                shutil.copyfile(os.path.join(folder, item["exportedFileName"]),
                                os.path.join(out, "summary." + kind))
EOF

if [[ ! -f $OUT/summary.json ]]; then
  print -u2 "no summary was attached (the run stopped early?); see $OUT/xcodebuild.log"
  exit 2
fi
print
cat "$OUT/summary.md"
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "$OUT/summary.json"
