#!/bin/zsh
# Write-and-lint base: do not run until the teacher completes the setup in README.md.
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

script_dir=${0:A:h}
# `renew.zsh --delivery-dry-run <absolute local folder>` runs only the optional delivery, copying the Outbox into
# that folder instead of the iPad's Documents/Inbox. It contacts no device, builds nothing and needs no enablement.
dry_run_target=
if [[ ${1:-} == --delivery-dry-run ]]; then
    dry_run_target=${2:-}
    [[ "$dry_run_target" == /* && -d "$dry_run_target" && ! -L "$dry_run_target" ]] \
        || { print -u2 'Dry run needs an absolute local folder to copy into.'; exit 64; }
elif (( $# )); then
    print -u2 'Usage: renew.zsh [--delivery-dry-run <absolute local folder>]'; exit 64
fi
config_file=${EMBERPAD_RESIGN_CONFIG:-$script_dir/config.local.zsh}
[[ -f "$config_file" ]] || { print -u2 'EmberPad renewal is unconfigured. See resign/README.md.'; exit 64; }
source "$config_file"
[[ -z ${EMBERPAD_LIBRARY_DIR:-} ]] \
    || { print -u2 'EMBERPAD_LIBRARY_DIR was replaced by EMBERPAD_OUTBOX_DIR (the Companion Outbox). See resign/README.md.'; exit 64; }
python_bin=${EMBERPAD_PYTHON:-/opt/homebrew/bin/python3}
[[ -x "$python_bin" ]] || { print -u2 'Set EMBERPAD_PYTHON to Python 3.'; exit 64; }
helper="$script_dir/support.py"

# Clones the Outbox (APFS copy-on-write) so a Companion swap mid-copy cannot mix two Outboxes, then checks the
# clone against its own manifest. Prints the check's "<entries> <present> <absent>" line.
stage_outbox() {
    local destination=$1
    [[ "$EMBERPAD_OUTBOX_DIR" == /* && -d "$EMBERPAD_OUTBOX_DIR" && ! -L "$EMBERPAD_OUTBOX_DIR" ]] || return 64
    [[ -d "$EMBERPAD_OUTBOX_DIR/EmberLibrary" && ! -L "$EMBERPAD_OUTBOX_DIR/EmberLibrary" ]] || return 64
    mkdir -p "$destination"
    /bin/cp -cR "$EMBERPAD_OUTBOX_DIR/EmberLibrary" "$destination/" || return 1
    "$python_bin" "$helper" outbox-check "$destination" || return 1
}

if [[ -n "$dry_run_target" ]]; then
    [[ -n ${EMBERPAD_OUTBOX_DIR:-} ]] || { print -u2 'Set EMBERPAD_OUTBOX_DIR to the Companion Outbox.'; exit 64; }
    dry_work=$(mktemp -d "${TMPDIR:-/tmp}/emberpad-delivery-dry-run.XXXXXX")
    trap 'rm -rf -- "$dry_work"' EXIT
    counts=$(stage_outbox "$dry_work/outbox") || { print -u2 'Outbox is missing or damaged; prepare the iPad library in the Companion.'; exit 1; }
    # Same shape as the device copy below: the clone's contents merge into the destination folder.
    /usr/bin/ditto "$dry_work/outbox/" "$dry_run_target/"
    print -r -- "dry run: Outbox (entries present absent: $counts) copied into $dry_run_target/EmberLibrary; no device contacted."
    exit 0
fi

[[ ${EMBERPAD_RESIGN_ENABLED:-NO} == YES ]] || { print -u2 'EmberPad renewal is disabled.'; exit 64; }
: "${EMBERPAD_PROJECT:?Set the absolute path to EmberPad.xcodeproj}"
: "${EMBERPAD_DEVICE_ID:?Set the approved iPad identifier}"
: "${EMBERPAD_TEAM_ID:?Set the same Personal Team used for the first install}"
[[ -d "$EMBERPAD_PROJECT" && "$EMBERPAD_PROJECT" == /* ]] || exit 64
[[ "$EMBERPAD_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Invalid Personal Team ID'; exit 64; }

support_dir=${EMBERPAD_RENEWAL_DIR:-$HOME/Library/Application Support/EmberPad Renewal}
mkdir -p "$support_dir"
exec >> "$support_dir/renewal.log" 2>&1
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
if [[ "$renewal_due" == not-due && -z ${EMBERPAD_OUTBOX_DIR:-} ]]; then
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

# Optional phase-1 delivery, off unless EMBERPAD_OUTBOX_DIR is set. Never launch the app; it applies the library
# delivery on its next foreground, only for PDFs that arrived intact, and archives nothing until all of it arrived.
# An unchanged Outbox is copied again at most once a day.
if [[ -n ${EMBERPAD_OUTBOX_DIR:-} ]]; then
    counts=$(stage_outbox "$work_dir/outbox") || { failed 'Outbox is missing or damaged; prepare the iPad library in the Companion.'; exit 1; }
    digest=$(/usr/bin/shasum -a 256 "$work_dir/outbox/EmberLibrary/manifest.json") || { failed 'Could not hash the Outbox manifest.'; exit 1; }
    digest=${digest%% *}
    marker="$support_dir/delivered-manifest"
    last=()
    [[ -f "$marker" ]] && last=( $(<"$marker") )
    if [[ ${last[1]:-} == "$digest" ]] && (( $(date +%s) - ${last[2]:-0} < 86400 )); then
        print -r -- "$(date -u +%FT%TZ) Outbox unchanged since its last delivery; not copied."
        exit 0
    fi
    xcrun devicectl device copy to --device "$EMBERPAD_DEVICE_ID" --timeout 600 \
        --domain-type appDataContainer --domain-identifier "$bundle_id" \
        --source "$work_dir/outbox/" --destination Documents/Inbox --json-output "$work_dir/delivery.json" \
        || { failed 'Library delivery failed; the iPad keeps what arrived and retries on the next hourly tick.'; exit 1; }
    print -r -- "$digest $(date +%s)" > "$marker"
    print -r -- "$(date -u +%FT%TZ) Library delivery completed (entries present absent: $counts)."
fi
