import SwiftUI
import XCTest
@testable import EmberPad
@testable import EmberSyncKit

/// EP-10 visual evidence: renders the real `WorksheetCard` (badges, type,
/// Theme tokens) with synthetic fixture records only — no real library,
/// no student names — in light and dark, and writes the PNGs to the test
/// host's tmp dir. After a local `xcodebuild test` run, pull them out of the
/// booted simulator with e.g.
/// `xcrun simctl get_app_container <udid> dev.emberpad.placeholder data`
/// and copy `tmp/library-*.png` to `docs/screenshots/` for the EP-10 PR.
@MainActor
final class LibraryScreenshotTests: XCTestCase {
    func testLibraryCardsRenderLightAndDark() throws {
        let cards = try FixtureRecords.all
        for scheme: ColorScheme in [.light, .dark] {
            let content = LibraryGridSnapshot(records: cards)
                .frame(width: 900)
                .environment(\.colorScheme, scheme)
            var renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.uiImage else {
                XCTFail("Could not render the library grid snapshot (\(scheme == .light ? "light" : "dark"))")
                continue
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            let name = scheme == .light ? "library-grid-light" : "library-grid-dark"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        }
    }
}

/// Test-only snapshot: the real sidebar rows, class chips, card grid and
/// signing-banner treatments composed from synthetic fixtures.
private struct LibraryGridSnapshot: View {
    let records: [DocumentRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EmberPad")
                .font(Theme.libraryLargeTitle)
                .foregroundStyle(Theme.text)
            Theme.sidebarSectionHeader("Subjects")
            HStack(spacing: 8) {
                SnapshotChip("All classes", selected: true)
                SnapshotChip("MI PU3", selected: false)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 22)], spacing: 26) {
                ForEach(records, id: \.id) { record in
                    WorksheetCard(record: record, thumbnail: nil)
                }
            }
            SnapshotBanner(status: .warning)
            SnapshotBanner(status: .urgent)
        }
        .padding(24)
        .background(Theme.bg)
    }
}

private struct SnapshotChip: View {
    let title: String
    let selected: Bool
    init(_ title: String, selected: Bool) { self.title = title; self.selected = selected }
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? Theme.accent : Theme.surface2, in: Capsule())
            .foregroundStyle(selected ? Theme.onAccent : Theme.text2)
    }
}

private struct SnapshotBanner: View {
    let status: SigningStatus
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 4) {
                Text(status == .warning ? "EmberPad stops opening in 2 days." : "EmberPad stops opening tonight at 23:34.")
                    .font(.system(.body, weight: .semibold))
                Text("Keep the iPad on home Wi-Fi near the Mac tonight so it can renew. Your ink is safe either way.")
                    .font(Theme.meta)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(status == .warning ? Theme.warnSoft : Theme.dangerSoft,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(status == .warning ? Theme.warn : Theme.danger)
    }
}

private enum FixtureRecords {
    static var all: [DocumentRecord] {
        get throws {
            [
                try student(title: "Acids Tutorial", subject: "H2 Chemistry", classTag: "MI PU3",
                            status: .current, isUpdated: true, hasInk: true, paired: true),
                try student(title: "Energetics Worksheet", subject: "H2 Chemistry", classTag: nil,
                            status: .olderVersion, isUpdated: false, hasInk: true, paired: false),
                try student(title: "Vectors Practice", subject: "H2 Math", classTag: "MI PU3",
                            status: .current, isUpdated: false, hasInk: false, paired: true),
                try student(title: "Functions Revision", subject: "H2 Math", classTag: "MI PU3",
                            status: .current, isUpdated: false, hasInk: false, paired: false),
            ]
        }
    }

    private static var counter = 0

    private static func student(title: String, subject: String, classTag: String?,
                                status: DocumentStatus, isUpdated: Bool,
                                hasInk: Bool, paired: Bool) throws -> DocumentRecord {
        counter += 1
        let source = try SourcePath(classFolder: "MI PU3", relativePath: "fixture-\(counter).pdf")
        let key = try PaperKey(rawValue: "fixture-paper-\(counter)")
        let publication = try Publication(subject: subject, classTag: classTag, paperKey: key,
                                          role: .student, title: title)
        let entry = try ManifestEntry(source: source, sha256: ContentHash.digest(Data("fixture-\(counter)".utf8)),
                                      size: 128, modifiedAt: Date(), publication: publication)
        return DocumentRecord(source: entry, pageCount: 4, importedAt: Date(),
                              hasInk: hasInk, status: status, title: title,
                              isUpdated: isUpdated, pairedDocumentID: paired ? UUID() : nil)
    }
}
