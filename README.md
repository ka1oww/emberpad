# EmberPad

Base code for a personal offline iPad teaching app. The Ember House colour tokens, reusable type styles, original app and Companion artwork, and branded launch background are in place, along with the initial worksheet chrome; the remaining tool presentation and the teacher's on-device decisions are still pending. This is a development scaffold, not yet a classroom-ready release.

## Layout

| Path | Responsibility |
| --- | --- |
| `EmberPad.xcodeproj` | iPad app, macOS Companion, iOS unit-test bundle and inert `resign` aggregate target; local package dependency |
| `Apps/EmberPad` | SwiftUI library with UIKit PDFKit/PencilKit page overlays, model-owned ink and student-display scene |
| `Apps/Companion` | macOS menu-bar window: Ember Projects source folder, finished-pair counts per subject with a not-found list, phase-2 placeholders, with no networking |
| `Apps/EmberPadTests` | iOS unit tests of app-layer logic, hosted by the EmberPad app |
| `EmberSyncKit` | Swift package target: validated manifests, streaming SHA-256, update planning, disk storage, expiry parser, the macOS Ember Projects library reader and tests |
| `Config/Shared.xcconfig` | Final `EMBERPAD_BUNDLE_ID` `io.github.ka1oww.emberpad` for the iPad app; the Companion target appends `.companion` so it never shares the iPad's App ID |
| `resign` | Uninstalled renewal script, format helpers, disabled example config and LaunchAgent template |

No third-party app dependencies, extensions, entitlement files or capability-backed services. iPad deployment floor is 17.5, macOS floor is 14.0. The local build is Xcode 26.6 (17F113), iOS/macOS SDK 26.5. CI selects Xcode 26.6 on `macos-26`.

## Build and test without signing

```sh
swift test --package-path EmberSyncKit
xcodebuild -project EmberPad.xcodeproj -scheme EmberPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/emberpad-ios CODE_SIGNING_ALLOWED=NO build
UDID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; c=[x for v in d.values() for x in v]; print(next((x for x in c if x["name"].startswith("iPad")), c[0])["udid"])')
xcodebuild -project EmberPad.xcodeproj -scheme EmberPad \
  -configuration Debug -destination "id=$UDID" \
  -derivedDataPath /tmp/emberpad-test CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test
xcodebuild -project EmberPad.xcodeproj -scheme 'EmberPad Companion' \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/emberpad-mac CODE_SIGNING_ALLOWED=NO build
zsh -n resign/renew.zsh
plutil -lint resign/dev.emberpad.renew.plist
```

These commands do not install on a device, provision an App ID or need an Apple account. The bundle IDs are final: changing the iPad ID later means deleting the app and its ink. The checked-in `EmberPad.xcodeproj` and shared schemes are the source of truth. `Apps/EmberPad`, `Apps/Companion` and `Apps/EmberPadTests` are file-system synchronized folders, so adding or removing a `.swift` file there needs no `project.pbxproj` edit (`Info.plist` files stay referenced by path and are excluded from membership). Commit test changes with source changes.

The GitHub workflow runs package tests, both unsigned builds, the EmberPadTests simulator suite, and syntax/plist checks. Ink feel, touch routing, Pencil double-tap, rendering at 1x/2x, capture traits, external-display behavior and signing cannot be established by those checks.

## Offline library

Import PDFs with **Import from Files**, choosing an existing or new class name. Files open through security-scoped coordinated reads and are copied into the app. Encrypted/locked or unreadable PDFs are rejected. A Finder/Files delivery can also place PDFs at `Documents/Inbox/<Class>/<file>.pdf`; a loose Inbox PDF goes to `Unfiled`. Nested paths within a class are preserved as source identity. Inbox is checked on foreground and by **File Inbox**. Retained Inbox files are idempotent receipts, and are never deleted while a sender could be writing them. Symlink deliveries are skipped. No absent-file deletion is inferred from an incremental Inbox.

If separate import locations would otherwise share a class/path, EmberPad gives the later assignment an available visible filename suffix, preserving any existing suffixes. It remembers each source's assignment, so re-imports keep their identity across picker batch order, Inbox/Files arrival order and app/store reopen. A changed file at that same source path follows the version rules below.

Each document version has its own `Application Support/Library/<UUID>/` folder:

```text
original.pdf            # untouched PDF bytes for this version
doc.json                # format 2: source class/path/hash and publication record, dates, status, ink pages, paired copy
page-0.drawing          # zero-based PDF page, native PKDrawing.dataRepresentation()
page-1.drawing
```

The app's `DocumentSession` owns every page drawing and updates from `canvasViewDrawingDidChange`, independently of overlays. It saves about one second after changes and flushes on editor exit and backgrounding. Save errors stay visible; corrupt saved ink never silently becomes an empty drawing. Storage uses Documents/Application Support, with no reliance on Caches. Deleting the app still deletes this data; backup is a later phase.

Same path and checksum is a replay. New bytes without ink replace the current copy while retaining the prior folder in hidden `.Previous` for 30 days. New bytes with ink create an **Updated** copy and mark the annotated one **Older version**; ink never moves to new bytes. An open, uninked worksheet is pinned: changed deliveries wait until the editor closes so an old canvas cannot write onto a replacement PDF. Recheck Inbox after closing it. Previous-version pruning is an explicit store operation; the base keeps versions conservatively until that maintenance path is wired.

The complete-manifest planner also returns archive and no-download relink actions for Mac deletion/rename. Ambiguous identical hashes are imported and archived conservatively rather than assigning somebody else's ink. Phase 2 will apply full manifests through a transport; the current base has no networking or cloud folder access.

### Library model v2

A version-2 manifest gives every entry a publication record: subject, optional class tag, a stable paper key, role (`student` or `teacher`) and display title. Each paper key has at most one copy per role. Version-1 manifests and Inbox deliveries still load as Student copies whose subject is the class folder; a Teacher role is never inferred from a file or folder name. Format-1 `doc.json` files still load as Student copies and are upgraded to format 2 when next written. Format 2 keeps the publication record in `source` and stores `pairedDocumentID`: the single current copy of the opposite role with the same paper key, recomputed after document imports, replacements, relinks and archives.

A document's identity is its path plus role, and its role never changes, so one path may hold a Student and a Teacher copy and a role change files a new copy beside the archived old one. Student copies keep the rules above. Teacher copies cannot be inked in this version: the store refuses Teacher ink, a changed Teacher copy replaces in place, and a Teacher copy at a new path follows its paper key to its existing document. No rule replaces an inked document, moves ink onto other bytes or relinks across roles.

### Library source: Ember Projects (macOS)

`EmberLibrarySource` builds a version-2 manifest straight from `~/Documents/Ember Projects` (passed in; tests use synthetic trees). It only reads. Only the subject folders are walked (A-Math, H2 Chemistry, H2 Econs, H2 Math, H2 Physics, Pure Chemistry, Pure Physics), and symlinks are not followed. A project is listed only as a finished Student/Teacher pair, decided by records and SHA-256 values, never by file names:

The macOS Companion defaults to this folder and remembers a folder chosen with **Choose master folder…**. Click **Prepare iPad library** to read it on demand; opening the window or changing folders does not start a scan. The window shows finished-pair counts and projects with records but no finished pair. Preparation is read-only and keeps the snapshot in the window: it does not save a manifest or deliver files to the iPad. See the [light](docs/screenshots/companion-light.png) and [dark](docs/screenshots/companion-dark.png) screenshots.

- **R1, paper:** `paper.json` must have non-empty `paper.title`, `output.student_pdf` and `output.teacher_pdf` strings, and a `paper.subject` code matching the project's top-level subject folder. A matching `audit/visual/<build>.json` must have `status: pass` and `schema_version` `ember.visual-signoff/v1`, `ember.visual-signoff/v3`, `ember.visual-signoff/v4` or `ember.visual-signoff/v5`. These are the G11 schema versions present in the Ember library; any other or missing schema is rejected. Its `student_pdf_sha256` and `teacher_pdf_sha256` must match `artifacts/<build>/student.pdf` and `teacher.pdf`. The newest valid `reviewed_at` wins; among candidates tied at that time, the newest valid ISO 8601 `artifacts/<build>/build-record.json` `finished_at` wins. If any candidate tied at the newest review time lacks a valid finish timestamp, the project is a miss (`invalid-record`), with no older candidate fallback.
- **R2, tutorial:** `tutorial.tex`, plus `artifacts/latest.json` naming a build whose copies match its hashes (`{student, teacher}` or `{pdfs: {student: {sha256}, teacher: {sha256}}}`). An H2 Math tutorial also needs a JSON record under `evidence/` with schema `ember.math-tutorial-signoff/v1`, the same build id, both matching role hashes under `pdf_sha256` or `pdfs` (each hash may be a string or a `{sha256}` object), and a non-empty string `verbatim` approval.

Each role is the record key its hash matched, and both copies come from one build directory. Subject is the top-level folder. Class is the project-name prefix (`MI PU1-3`, `YIJC JC1-2`, `NYJC-EJC JC1-2`, `SEC 1-4`), or a prefix from the alias table loaded from `~/Library/Application Support/EmberPad/class-aliases.json` and passed to `EmberLibrarySource` (synthetic example: `EmberSyncKit/Examples/class-aliases.example.json`). Alias values must be known class codes or short uppercase tags matching `^[A-Z0-9][A-Z0-9-]{0,11}( [A-Z0-9][A-Z0-9-]{0,11}){0,2}$`; other values are skipped and counted. Every `Sec 1-4` or `S1-4` token is checked against the complete word segment before it (after the preceding section token, if any): it must be empty, a class code or an alias key. Otherwise that segment's words are withheld and removed, and the class tag is nil (**All classes**). Non-class name words in alias keys and configured `withhold` terms are also withheld. The real table is personal data and never goes in the repository. A final check rejects any pair whose emitted class tag is invalid, or whose source path, title, subject or paper key still contains a personal-name shape or withheld term. A pair whose Student bytes equal any Teacher copy is held back, as are projects that would share a paper key. Build ids and project folders stay on the Mac and never go in the manifest.

The snapshot also returns a miss list (projects with a record but no finished pair, with a reason) and the local file for each copy. Pass the previously delivered manifest as `previous`: a paper that is not found again is carried forward unchanged, so a vanished source means "no update" and the planner never archives it. Single-copy material and a fallback to the Drive main folder are not included yet. The fallback waits on an open captain question; `LibraryFallbackSource` is its extension point.

## Page and presentation seams

`WorksheetPageRenderer`/`PageRendererFactory` isolate option A (`PDFView` with a `PKCanvasView` overlay per page) from a later option B. `DocumentSession` and the storage layout survive that replacement. The worksheet scrolls continuously (vertical, 16 pt page gaps with shadows on the canvas token); every ink canvas is forced to the light style so black ink never inverts in dark mode.

Theme tokens are defined in `Apps/EmberPad/Theme.swift`; the app chrome uses light/dark color sets in `Apps/EmberPad/Assets.xcassets`, while ink colors stay fixed for the white worksheet page. The current fountain-pen default is black, and the marker default is translucent yellow. See the [light](docs/screenshots/theme-tokens-light.png) and [dark](docs/screenshots/theme-tokens-dark.png) token previews. The editor nav bar (serif title with page/save caption, share pill, Teacher-copy toggle, undo/redo, More menu), the capture-leak and ink-not-saved banners, and the page pill use those tokens; the GoodNotes-style toolbar strip and the floating Teacher card are later packages.

The original worksheet-and-pen AppIcon and `bg`-coloured iOS launch screen, plus the Companion's monochrome menu-bar glyph and window badge, are documented with their vector sources and raster exporters in the [iPad](Apps/EmberPad/Brand.Sources/README.md) and [Companion](Apps/Companion/Brand.Sources/README.md) source notes. See the [home-screen icon screenshot](docs/screenshots/home-screen-icon.png).

The iOS 18+ system picker requests fountain pen, marker, partial and stroke erasers, and lasso. The Tools menu provides the exact tools on 17.5 too, where the legacy picker cannot be restricted. Worksheet drawing is Pencil-only; fingers pan/zoom. Undo/redo buttons and multi-finger double-taps route to the active canvas. The system picker owns Apple Pencil double-tap preferences. Validate its two eraser items and touch/undo behavior on the actual iPad before relying on it.

The external scene uses `UIWindowSceneSessionRoleExternalDisplayNonInteractive`. Its model accepts only a worksheet page and committed drawing. It shows a neutral **Paused** view while the main scene is inactive. The base follows the current page in full-page mode; in-progress strokes, follow-zoom and external-scene recording are future work.

Debug builds expose **Device checks** in the library's Debug section, with pass/fail results for the scene, log, PDF and Pencil checks. The probe appends scene and capture snapshots to `Documents/device-checks.log`, provides a runtime-generated synthetic writing-trial PDF, and can replace the external student scene with a solid-colour, role-labelled test pattern. Its scribble recorder accepts Pencil or touch input, labels each saved drawing `erase` or `keep`, and exports the collected stroke samples as versioned JSON through Files. Samples are held in recorder state and are not persisted unless exported; they are not added to the device-check log or uploaded. These controls are compiled out of Release builds.

`sceneCaptureState` masks the private-answer seam when the main scene is captured without an external scene, and whenever inactive. No pairing policy is implemented and no private-answer URL is assigned. This is a guard skeleton, not a privacy guarantee. AirPlay/HDMI, QuickTime, recording and capture-trait behavior must be checked with the teacher. Leaving the app can restore system mirroring; stay in EmberPad while sharing. There are no private UIKit capture-hiding tricks or iOS 27 APIs.

The library reads `embedded.mobileprovision` best-effort: amber at 48 hours or less, red below 24 hours, unknown when absent/malformed (normal for unsigned Simulator builds). This parses only a reminder, not a signature or security decision. The current display reports Inbox delivery time, not a fabricated network sync time.

## Open items for the teacher

- Personal Team, Developer Mode, first cable install/trust and network pairing. See [renewal setup](resign/README.md). Nothing in `resign/` has been installed, loaded or run against an account/device.
- Fountain-pen feel; option A ink quality at 1x and 2x; Pencil model and double-tap; lasso/eraser expectations; undo after moving between pages.
- **Must resolve before first classroom use:** Teacher copies are identified by a version-2 manifest's role, but nothing yet keeps them off the student view: opening any PDF while an external display is connected mirrors it to the student view. Do not open answer PDFs while sharing.
- External-display sharing/recording method and capture tests.
- Joint planning before phase 2+: Bonjour/TLS-PSK pairing and wire framing, iCloud/Drive, live ink, external-scene recording, scribble detection, library backup/export, lasso/eraser extras, and any Ember publish hook.
- The on-device automation trial: same account and approved iPad bundle ID, awake Mac on home Wi-Fi, occasional Xcode reauthentication and one unlock after iPad restarts. Keep iPadOS 26.x until a later version is tested.

No GoodNotes binaries or GPL implementation code are included. Tests use synthetic data and contain no students, contacts or rosters.
