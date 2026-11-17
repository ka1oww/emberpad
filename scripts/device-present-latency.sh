#!/bin/zsh
# Measures pen-to-projector latency of Present on Mac between an iPad and this Mac (EP148).
#
#   scripts/device-present-latency.sh <device-udid> <output-dir>
#
# The UDID can be a connected iPad's (`xcrun devicectl list devices`) or a simulator's. On a
# physical iPad, set DEVELOPMENT_TEAM to the signing team's ID first, as for
# scripts/device-stress-test.sh.
#
# What it does. It builds a debug Ember Companion and starts it as a latency host: a bare app
# that presents for one pairing made for this run, with the Companion's own presentation window,
# lesson recording and sync server. It then runs DevicePresentLatencyTests on the iPad inside
# "Ember Stress" (io.github.ka1oww.emberpad.stresstest), which writes on a worksheet with a
# synthetic Pencil while the real Present streams the page to the host over the real link, and
# times every Pencil sample: once without a lesson recording, once while the Mac records.
#
# What it touches. On the iPad only Ember Stress, never Ember Slate. Ember Stress is left
# installed between runs, so iPadOS asks for Local Network access only the first time: tap
# Allow when it does (the test waits 90 seconds for the link). On the Mac the host never reads
# the Companion's pairing, the Keychain or the library, and records its lesson (a synthetic
# worksheet with a synthetic microphone) into <output-dir>/lessons, never the lessons folder.
# The teacher's own Ember Companion can stay open; it is not involved. The Mac shows the
# presentation window as in class (on the projector when one is attached) for the minute or so
# the run takes. Keep the iPad awake and unlocked.
#
# The run's pairing is a secret while the host lives. It is kept in a private temporary folder,
# handed to the test in its environment, never printed, and worthless once the host quits at the
# end of this script.
#
# EMBERPAD_LATENCY_HEADLESS=1 keeps the Mac's window invisible and the host in the background, as
# the Companion's tests do: for a dry run of this script on a simulator, not for a measurement.
#
# Output (all in <output-dir>):
#   present-latency.md            each part's p50, p95 and max in milliseconds, for both runs
#   present-latency.json          the same, machine-readable (schema emberpad.present-latency/1)
#   present-latency-samples.json  every sample of the last run, part by part
#   attachments/, commit.txt, PresentLatency.xcresult, xcodebuild.log, companion-build.log, host.log
# Exit status: 0 when the test passed, 1 when it failed, 2 for a usage or build problem.
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
MAC_DERIVED=${EMBERPAD_LATENCY_MAC_DERIVED_DATA:-${TMPDIR:-/tmp}/emberpad-present-latency-mac-dd}

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
rm -rf "$OUT/PresentLatency.xcresult" "$OUT/attachments" "$OUT"/present-latency*(N)
print "Present latency on $KIND $UDID as $STRESS_BUNDLE_ID; results in $OUT"
print "commit $(git -C "$ROOT" rev-parse HEAD 2>/dev/null)$( [[ -n $(git -C "$ROOT" status --porcelain 2>/dev/null) ]] && print ' (with uncommitted changes)')" \
  | tee "$OUT/commit.txt"

# The Mac end: a debug Companion, unsigned, run from its build folder. It is never installed.
xcodebuild -project "$ROOT/EmberPad.xcodeproj" -scheme 'EmberPad Companion' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$MAC_DERIVED" CODE_SIGNING_ALLOWED=NO build > "$OUT/companion-build.log" 2>&1
APP=("$MAC_DERIVED"/Build/Products/Debug/*.app(N/))
COMPANION=
if [[ ${#APP} -eq 1 ]]; then
  COMPANION=$APP[1]/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP[1]/Contents/Info.plist" 2>/dev/null)
fi
if [[ ! -x $COMPANION || -d $COMPANION ]]; then
  print -u2 "the Companion did not build; see $OUT/companion-build.log"
  tail -20 "$OUT/companion-build.log" >&2
  exit 2
fi

SECRET=$(mktemp -d "${TMPDIR:-/tmp}/emberpad-present-latency.XXXXXX")
chmod 700 "$SECRET"
HOST_PID=
cleanup() {
  [[ -n $HOST_PID ]] && kill "$HOST_PID" 2>/dev/null
  rm -rf "$SECRET"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

HOST_ENV=()
# The Companion keeps its windows invisible and never comes to the front when it believes it hosts its tests.
[[ ${EMBERPAD_LATENCY_HEADLESS:-0} == 1 ]] && HOST_ENV=(XCTestSessionIdentifier=present-latency-dry-run)
env "${HOST_ENV[@]}" "$COMPANION" -EmberPresentLatencyHost "$SECRET/pairing" -EmberLessonRoot "$OUT/lessons" \
  > "$OUT/host.log" 2>&1 &
HOST_PID=$!
for _ in {1..150}; do
  [[ -s $SECRET/pairing ]] && break
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -s $SECRET/pairing ]]; then
  print -u2 "the Mac's latency host did not start; see $OUT/host.log"
  tail -20 "$OUT/host.log" >&2
  exit 2
fi
print "Mac latency host running (pid $HOST_PID)"

# TEST_RUNNER_ variables reach the test process with the prefix removed. EMBERPAD_STRESS=1 and the
# pairing are the gate: without both, and outside the separate stress-test app, the test skips itself.
export TEST_RUNNER_EMBERPAD_STRESS=1
export TEST_RUNNER_EMBERPAD_PRESENT_LATENCY=$(<"$SECRET/pairing")
[[ -n ${EMBERPAD_STRESS_ORIENTATION:-} ]] && export TEST_RUNNER_EMBERPAD_STRESS_ORIENTATION=$EMBERPAD_STRESS_ORIENTATION

xcodebuild -project "$ROOT/EmberPad.xcodeproj" -scheme EmberPad -configuration Debug \
  -destination "id=$UDID" -destination-timeout 120 -derivedDataPath "$DERIVED" \
  -resultBundlePath "$OUT/PresentLatency.xcresult" \
  -only-testing:EmberPadTests/DevicePresentLatencyTests \
  EMBERPAD_BUNDLE_ID=$STRESS_BUNDLE_ID EMBERPAD_DISPLAY_NAME="Ember Stress" ONLY_ACTIVE_ARCH=YES \
  "${SIGNING[@]}" test > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
unset TEST_RUNNER_EMBERPAD_PRESENT_LATENCY

# Asked to quit, the host finishes a lesson still recording first; it is given ten seconds.
kill "$HOST_PID" 2>/dev/null
for _ in {1..100}; do
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 0.1
done
kill -9 "$HOST_PID" 2>/dev/null
wait "$HOST_PID" 2>/dev/null
HOST_PID=

grep -E "^Test Case .*(passed|failed|skipped)|error: " "$OUT/xcodebuild.log" | cut -c1-300

if [[ ! -d $OUT/PresentLatency.xcresult ]]; then
  print -u2 "xcodebuild made no result bundle (exit $STATUS); see $OUT/xcodebuild.log"
  tail -20 "$OUT/xcodebuild.log" >&2
  exit 2
fi
xcrun xcresulttool export attachments --path "$OUT/PresentLatency.xcresult" --output-path "$OUT/attachments" >/dev/null 2>&1

# The test attaches its report; copy it out under predictable names.
python3 -I - "$OUT" <<'EOF'
import json, os, re, shutil, sys
out = sys.argv[1]
folder = os.path.join(out, "attachments")
try:
    manifest = json.load(open(os.path.join(folder, "manifest.json")))
except Exception:
    manifest = []
for test in manifest:
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        # xcresulttool names an attachment "present-latency.json" as "present-latency_0_<UUID>.json".
        for wanted in ("present-latency-samples.json", "present-latency.json", "present-latency.md"):
            stem, kind = wanted.rsplit(".", 1)
            if re.fullmatch(re.escape(stem) + r"(_\d+_[0-9A-Fa-f-]+)?\." + kind, name):
                shutil.copyfile(os.path.join(folder, item["exportedFileName"]), os.path.join(out, wanted))
EOF

if [[ ! -f $OUT/present-latency.md ]]; then
  print -u2 "no report was attached (the test skipped or stopped early?); see $OUT/xcodebuild.log"
  exit 2
fi
print
cat "$OUT/present-latency.md"
[[ $STATUS -eq 0 ]] && exit 0
exit 1
