#!/bin/zsh
# Write-and-lint base: do not run until the teacher completes the setup in README.md.
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

script_dir=${0:A:h}
config_file=${EMBERPAD_RESIGN_CONFIG:-$script_dir/config.local.zsh}
[[ -f "$config_file" ]] || { print -u2 'EmberPad renewal is unconfigured. See resign/README.md.'; exit 64; }
source "$config_file"
[[ ${EMBERPAD_RESIGN_ENABLED:-NO} == YES ]] || { print -u2 'EmberPad renewal is disabled.'; exit 64; }
: "${EMBERPAD_PROJECT:?Set the absolute path to EmberPad.xcodeproj}"
: "${EMBERPAD_DEVICE_ID:?Set the approved iPad identifier}"
: "${EMBERPAD_TEAM_ID:?Set the same Personal Team used for the first install}"
[[ -d "$EMBERPAD_PROJECT" && "$EMBERPAD_PROJECT" == /* ]] || exit 64
[[ "$EMBERPAD_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Invalid Personal Team ID'; exit 64; }

python_bin=${EMBERPAD_PYTHON:-/opt/homebrew/bin/python3}
[[ -x "$python_bin" ]] || { print -u2 'Set EMBERPAD_PYTHON to Python 3.'; exit 64; }
support_dir=${EMBERPAD_RENEWAL_DIR:-$HOME/Library/Application Support/EmberPad Renewal}
mkdir -p "$support_dir"
exec >> "$support_dir/renewal.log" 2>&1
helper="$script_dir/support.py"
state_file="$support_dir/install-state.json"
lock_dir="$support_dir/job.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    print 'Another renewal owns job.lock. If a prior run crashed, inspect it before removing the lock.'
    exit 0
fi
work_dir=$(mktemp -d "$support_dir/.run.XXXXXX")
cleanup() { rm -rf -- "$work_dir"; rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup EXIT

notify_once() {
    local kind=$1
    local message=$2
    local marker="$support_dir/notice-$kind"
    [[ -e "$marker" ]] && return 0
    /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "EmberPad"' -e 'end run' -- "$message" || true
    touch "$marker"
}

failed() {
    local message=$1
    print -r -- "$(date -u +%FT%TZ) failed: $message"
    local seconds_left
    seconds_left=$("$python_bin" "$helper" seconds-left "$state_file")
    if (( seconds_left >= 0 && seconds_left < 86400 )); then
        notify_once expiry 'iPad app expires tomorrow. Unlock it near the Mac on home Wi-Fi.'
    fi
}

# A lapsed Xcode login is a human step. Do not hammer Apple's services until it is cleared.
if [[ -e "$support_dir/credentials-paused" ]]; then
    failed 'Renewal paused until Xcode sign-in is repaired and credentials-paused is removed.'
    exit 0
fi

bundle_id=$("$python_bin" "$helper" bundle-id "${EMBERPAD_PROJECT:h}/Config/Shared.xcconfig")
renewal_due=$("$python_bin" "$helper" due "$state_file")
if [[ "$renewal_due" == not-due && -z ${EMBERPAD_LIBRARY_DIR:-} ]]; then
    print -r -- "$(date -u +%FT%TZ) not due; at least four days remain."
    exit 0
fi

# Read only the approved device's readiness before any build or install.
if ! xcrun devicectl list devices --timeout 30 --json-output "$work_dir/devices.json"; then
    failed 'Device discovery failed; retry at the next hourly calendar tick.'; exit 1
fi
if ! xcrun devicectl device info details --device "$EMBERPAD_DEVICE_ID" --timeout 30 --json-output "$work_dir/details.json"; then
    failed 'iPad unreachable; retry at the next hourly calendar tick.'; exit 1
fi
if ! xcrun devicectl device info lockState --device "$EMBERPAD_DEVICE_ID" --timeout 30 --json-output "$work_dir/lock.json"; then
    failed 'Could not read the iPad lock state.'; exit 1
fi
if ! "$python_bin" "$helper" readiness "$work_dir/devices.json" "$work_dir/details.json" "$work_dir/lock.json" "$EMBERPAD_DEVICE_ID" > "$work_dir/readiness.txt" 2>&1; then
    failed "$(<"$work_dir/readiness.txt")"
    notify_once readiness 'Unlock the iPad once near the Mac on home Wi-Fi. Check the renewal log if it still fails.'
    exit 1
fi

if [[ "$renewal_due" == due ]]; then
    derived_data="$support_dir/DerivedData"
    app_path="$derived_data/Build/Products/Release-iphoneos/EmberPad.app"
    fresh_expiry=0
    for attempt in 1 2; do
        if ! xcodebuild -project "$EMBERPAD_PROJECT" -scheme EmberPad -configuration Release \
            -destination "id=$EMBERPAD_DEVICE_ID" -derivedDataPath "$derived_data" \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
            "DEVELOPMENT_TEAM=$EMBERPAD_TEAM_ID" CODE_SIGNING_ALLOWED=YES build > "$work_dir/build.log" 2>&1; then
            cat "$work_dir/build.log"
            if /usr/bin/grep -Eiq 'Your session has expired|Code[= ]+1100|Invalid credentials in keychain' "$work_dir/build.log"; then
                touch "$support_dir/credentials-paused"
                notify_once credentials 'Open Xcode → Settings → Accounts and sign in again. Then clear the renewal pause as described in the README.'
            fi
            failed 'Signing build failed; no install attempted.'; exit 1
        fi
        /usr/bin/security cms -D -i "$app_path/embedded.mobileprovision" > "$work_dir/profile.plist"
        fresh_expiry=$("$python_bin" "$helper" expiry "$work_dir/profile.plist")
        if (( fresh_expiry - $(date +%s) >= 6 * 86400 )); then break; fi
        print -r -- "Cached short-lived profile after build attempt $attempt; retrying once without removing shared profiles."
    done
    if (( fresh_expiry - $(date +%s) < 6 * 86400 )); then
        notify_once profile 'Xcode reused a short-lived profile. Open the project in Xcode and inspect signing.'
        failed 'Profile did not renew to approximately seven days; existing install kept.'; exit 1
    fi

    installed=NO
    for attempt in 1 2 3; do
        if xcrun devicectl device install app --device "$EMBERPAD_DEVICE_ID" --timeout 120 \
            --json-output "$work_dir/install.json" "$app_path"; then
            installed=YES; break
        fi
        (( attempt == 3 )) || sleep 10
    done
    if [[ "$installed" != YES ]]; then failed 'Install failed after three bounded attempts.'; exit 1; fi
    "$python_bin" "$helper" record-install "$state_file" "$fresh_expiry" "$bundle_id"
    rm -f -- "$support_dir/notice-expiry" "$support_dir/notice-profile" "$support_dir/notice-readiness" "$support_dir/notice-credentials"
    print -r -- "$(date -u +%FT%TZ) installed; expiry=$fresh_expiry"
fi

# Optional phase-1 delivery. Never launch the app; it files Inbox PDFs on its next foreground.
if [[ -n ${EMBERPAD_LIBRARY_DIR:-} ]]; then
    [[ -d "$EMBERPAD_LIBRARY_DIR" && "$EMBERPAD_LIBRARY_DIR" == /* ]] || { failed 'Master folder must be an absolute local directory.'; exit 64; }
    xcrun devicectl device copy to --device "$EMBERPAD_DEVICE_ID" --timeout 180 \
        --domain-type appDataContainer --domain-identifier "$bundle_id" \
        --source "$EMBERPAD_LIBRARY_DIR/" --destination Documents/Inbox --json-output "$work_dir/delivery.json" \
        || { failed 'Worksheet delivery failed; retry on the next hourly tick.'; exit 1; }
    print -r -- "$(date -u +%FT%TZ) Inbox delivery completed."
fi
