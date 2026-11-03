# Renewal tooling: written and linted only

This folder is deliberately inert. The Xcode `resign` aggregate has no build phases. `renew.zsh` is not installed, not scheduled, and rejects the example config. Do not enable it until the teacher is present for the following steps. Do not point it at an arbitrary paired device.

## One-time supervised setup

1. The final bundle ID is approved and set: `EMBERPAD_BUNDLE_ID` in `Config/Shared.xcconfig` is `io.github.ka1oww.emberpad` for the iPad app, and the non-sandboxed Mac Companion target uses `io.github.ka1oww.emberpad.companion` so it never shares the iPad's App ID. The Mac target needs no mobile provisioning profile. Never change the iPad ID: a new ID consumes a free-account slot and loses the app's ink, so do not experiment by signing new IDs.
2. Use the same Apple Account/Personal Team for the lifetime of the iPad app. Sign in to Xcode's Accounts pane, select that team for the first build, and leave the account settings unchanged thereafter. The script never changes accounts, revokes certificates or deletes shared profiles.
3. On the iPad, enable Developer Mode and complete its restart/confirmation. Make the first cable install in Xcode and trust the developer when required. Enable **Connect via network** in Devices and Simulators. The teacher verifies the approved device identifier for `config.local.zsh`.
4. Test fountain-pen feel and option A at 1x/2x zoom. Test AirPlay/HDMI student output, touching private answers, inactivity, main-screen capture, the capture trait, and the actual sharing/recording path. These are go/no-go checks before teaching from the app.
5. Keep Mac and iPad on the same real home Wi-Fi, Mac awake on a charger and logged into its GUI account. Unlock the iPad once after each restart/update. Keep its OS at a tested 26.x release.
6. Copy `config.example.zsh` to the ignored `config.local.zsh` in a permanent checkout, supply absolute paths, the verified iPad identifier and Personal Team ID. Confirm Python 3's absolute path. Optional `EMBERPAD_LIBRARY_DIR` must be a dedicated local master folder, outside iCloud/CloudStorage, with `<Class>/<worksheet>.pdf` children. Keep the config private and outside git history.
7. Inspect this Xcode version's JSON during the first supervised run. The helper recognizes both nested and flattened properties by key presence, selects exactly the configured identifier/UDID, requires pairing and mounted DDI, and validates the `passcodeRequired` boolean. An unknown schema stops the job. Validate locked-screen installation and Inbox destination layout over Wi-Fi; these have not been tested on this device.
8. Once approved, set `EMBERPAD_RESIGN_ENABLED=YES` in the private config. Prepare a separate copy of `dev.emberpad.renew.plist`, replacing `__REPO_PATH__` and `__CONFIG_PATH__` with their approved absolute values. The template already associates the job with the approved iPad bundle ID. Lint it, then install it as a per-user **LaunchAgent** in the logged-in Aqua session only with the teacher's agreement. Do not use a LaunchDaemon or SSH for signing. Allow macOS Local Network access if prompted. Validate from launchd itself because that privacy context differs from Terminal.
9. Observe renewal from launchd for two weeks, including an asleep/unreachable iPad, a restart/unlock and an in-place reinstall that preserves ink, before depending on it. The base-code worker has performed none of these steps.

## Behavior after enablement

The template checks at login and at each clock hour. Calendar jobs missed during sleep are coalesced on wake; it does not wake a sleeping Mac. It rebuilds only when the last successfully installed profile has **fewer than four days** left or there is no success record. Optional Inbox delivery can run on every check even when renewal is not due.

It checks reachability, pairing, Developer Mode, lock state and the mounted Developer Disk Image. An unavailable device is retried next hour; a locked device is allowed only with DDI already mounted. This remains a device-test assumption, not a proven unattended-install guarantee.

Signing uses `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration` against the explicit iPad destination. It decodes the built profile with `security cms` and requires at least six days remaining (approximately a fresh seven-day profile). If the cached profile is too old it rebuilds once, then stops and notifies rather than deleting shared profiles. Installation uses `xcrun devicectl device install app`, with up to three bounded attempts for transient failures. It **never launches the app** and never deletes it. Optional delivery uses `devicectl device copy to` into `Documents/Inbox`; the app files PDFs on its next open.

All job data goes to `~/Library/Application Support/EmberPad Renewal/` with private permissions: `renewal.log`, `install-state.json` (last successful install, embedded-profile expiry, bundle ID and result), build products, locks and notification markers. A failed build/install never advances the success timestamp or expiry. That expiry describes the installed profile, not an uninstalled build.

Known credential strings pause renewal and notify once: **Open Xcode → Settings → Accounts and sign in again**. After the teacher repairs sign-in, remove `credentials-paused` and `notice-credentials` in that job directory to resume at the next check. The job does not automate 2FA or modify Xcode account preferences. Notifications also explain low expiry or an unlock/readiness issue. Inspect a stale `job.lock` after a crash before removing it; never clear a lock while a job is running.

## Static validation only

```sh
zsh -n resign/renew.zsh
zsh -n resign/config.example.zsh
plutil -lint resign/dev.emberpad.renew.plist
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("resign/support.py").read_text())'
```

The script, device JSON assumptions, account refresh, notifications, LaunchAgent privacy and real reinstall retention need the supervised trial. Do not call `renew.zsh` as a lint or test command. Expiry stops the iPad app opening; same-team, same-ID reinstall should retain its Documents/Application Support. Switching teams or deleting the app can lose all ink. Backup/export remains a later phase.
