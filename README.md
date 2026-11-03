# EmberPad

Base code for a personal offline iPad teaching app. Visual design and the teacher's on-device decisions are still pending. This is a development scaffold, not yet a classroom-ready release.

## Layout

| Path | Responsibility |
| --- | --- |
| `EmberPad.xcodeproj` | iPad app, macOS Companion, iOS unit-test bundle and inert `resign` aggregate target; local package dependency |
| `Apps/EmberPad` | SwiftUI library with UIKit PDFKit/PencilKit page overlays, model-owned ink and student-display scene |
| `Apps/Companion` | macOS menu-bar shell: choose a local folder and generate a manifest preview, with no networking |
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

- **R1, paper:** `paper.json`, plus an `audit/visual/<build>.json` with `status: pass` whose `student_pdf_sha256` and `teacher_pdf_sha256` match `artifacts/<build>/student.pdf` and `teacher.pdf`. The newest `reviewed_at` wins, then the build record's `finished_at`.
- **R2, tutorial:** `tutorial.tex`, plus `artifacts/latest.json` naming a build whose copies match its hashes (`{student, teacher}` or `{pdfs: {student: {sha256}, teacher: {sha256}}}`). An H2 Math tutorial also needs a JSON record under `evidence/` with schema `ember.math-tutorial-signoff/v1`, the same build id and both matching hashes (`pdf_sha256` or `pdfs`), and a non-empty string `verbatim` approval.

Each role is the record key its hash matched, and both copies come from one build directory. Subject is the top-level folder. Class is the project-name prefix (`MI PU1-3`, `YIJC JC1-2`, `NYJC-EJC JC1-2`, `SEC 1-4`), or a prefix from the local alias table at `~/Library/Application Support/EmberPad/class-aliases.json` (synthetic example: `EmberSyncKit/Examples/class-aliases.example.json`). The real table is personal data and never goes in the repository. Otherwise the class tag is nil, shown as **All classes**. A personal-name-shaped prefix (`<word> Sec 3`, `<word> S3`) with no alias is dropped from every manifest string. A pair whose path, title or key would still carry a withheld term is held back. So is a pair whose Student bytes equal any Teacher copy, and so are projects that would share a paper key. Build ids and project folders stay on the Mac and never go in the manifest.

The snapshot also returns a miss list (projects with a record but no finished pair, with a reason) and the local file for each copy. Pass the previously delivered manifest as `previous`: a paper that is not found again is carried forward unchanged, so a vanished source means "no update" and the planner never archives it. Single-copy material and a fallback to the Drive main folder are not included yet. The fallback waits on an open captain question; `LibraryFallbackSource` is its extension point.

## Page and presentation seams

`WorksheetPageRenderer`/`PageRendererFactory` isolate option A (`PDFView` with a `PKCanvasView` overlay per page) from a later option B. `DocumentSession` and the storage layout survive that replacement. A provisional vertical layout enables the spike; it is not the teacher's final navigation choice.

The iOS 18+ system picker requests fountain pen, marker, partial and stroke erasers, and lasso. The Tools menu provides the exact tools on 17.5 too, where the legacy picker cannot be restricted. Drawing is Pencil-only; fingers pan/zoom. Undo/redo buttons and multi-finger double-taps route to the active canvas. The system picker owns Apple Pencil double-tap preferences. Validate its two eraser items and touch/undo behavior on the actual iPad before relying on it.

The external scene uses `UIWindowSceneSessionRoleExternalDisplayNonInteractive`. Its model accepts only a worksheet page and committed drawing. It shows a neutral **Paused** view while the main scene is inactive. The base follows the current page in full-page mode; in-progress strokes, follow-zoom and recording are future work.

`sceneCaptureState` masks the private-answer seam when the main scene is captured without an external scene, and whenever inactive. The presentation layer does not use roles or pairs yet, and no private-answer URL is assigned. This is a guard skeleton, not a privacy guarantee. AirPlay/HDMI, QuickTime, recording and capture-trait behavior must be checked with the teacher. Leaving the app can restore system mirroring; stay in EmberPad while sharing. There are no private UIKit capture-hiding tricks or iOS 27 APIs.

The library reads `embedded.mobileprovision` best-effort: amber at 48 hours or less, red below 24 hours, unknown when absent/malformed (normal for unsigned Simulator builds). This parses only a reminder, not a signature or security decision. The current display reports Inbox delivery time, not a fabricated network sync time.

## Open items for the teacher

- Personal Team, Developer Mode, first cable install/trust and network pairing. See [renewal setup](resign/README.md). Nothing in `resign/` has been installed, loaded or run against an account/device.
- Fountain-pen feel; option A ink quality at 1x and 2x; Pencil model and double-tap; lasso/eraser expectations; undo after moving between pages.
- **Must resolve before first classroom use:** Teacher copies are identified by a version-2 manifest's role, but nothing yet keeps them off the student view: opening any PDF while an external display is connected mirrors it to the student view. Do not open answer PDFs while sharing.
- Sharing/recording method and the external-display/capture tests.
- Scroll versus page navigation, visual design and tool presentation.
- Joint planning before phase 2+: Bonjour/TLS-PSK pairing and wire framing, iCloud/Drive, live ink, recording, scribble detection, backup/export, lasso/eraser extras, and any Ember publish hook.
- The on-device automation trial: same account and approved iPad bundle ID, awake Mac on home Wi-Fi, occasional Xcode reauthentication and one unlock after iPad restarts. Keep iPadOS 26.x until a later version is tested.

No GoodNotes binaries or GPL implementation code are included. Tests use synthetic data and contain no students, contacts or rosters.
