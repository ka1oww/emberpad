import SwiftUI
import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

/// P2: an open worksheet gets the whole screen, and the library cards keep their titles level.
@MainActor
final class LibraryColumnStateTests: XCTestCase {
    func testOpeningWorksheetHidesSidebarInRegularWidthAndBackRestoresIt() {
        var columns = LibraryColumnState()
        columns.sizeClassChanged(to: .regular)
        XCTAssertEqual(columns.visibility, .all)

        columns.worksheetOpened()
        XCTAssertTrue(columns.isWorksheetOpen)
        XCTAssertEqual(columns.visibility, .detailOnly)

        columns.worksheetClosed()
        XCTAssertFalse(columns.isWorksheetOpen)
        XCTAssertEqual(columns.visibility, .all)
    }

    func testBackRestoresTheVisibilityTheTeacherChose() {
        var columns = LibraryColumnState()
        columns.sizeClassChanged(to: .regular)
        columns.visibility = .detailOnly  // sidebar hidden from the system toggle before opening

        columns.worksheetOpened()
        XCTAssertEqual(columns.visibility, .detailOnly)
        columns.worksheetClosed()
        XCTAssertEqual(columns.visibility, .detailOnly)
    }

    func testRotatingWhileWorksheetOpenKeepsSidebarHiddenAndUpdatesRestore() {
        var columns = LibraryColumnState()
        columns.sizeClassChanged(to: .compact)
        XCTAssertEqual(columns.visibility, .detailOnly)

        columns.worksheetOpened()
        columns.sizeClassChanged(to: .regular)
        XCTAssertEqual(columns.visibility, .detailOnly, "a size change must not bring the sidebar back over the page")

        columns.worksheetClosed()
        XCTAssertEqual(columns.visibility, .all)
    }

    /// EP54: the worksheet header's sidebar button shows the library beside the page and hides it
    /// again.
    func testHeaderSidebarButtonTogglesTheLibraryWhileAWorksheetIsOpen() {
        var columns = LibraryColumnState()
        columns.sizeClassChanged(to: .regular)
        columns.toggleSidebar()
        XCTAssertEqual(columns.visibility, .all, "the toggle does nothing on the library itself")

        columns.worksheetOpened()
        XCTAssertEqual(columns.visibility, .detailOnly)
        columns.toggleSidebar()
        XCTAssertEqual(columns.visibility, .all)
        columns.toggleSidebar()
        XCTAssertEqual(columns.visibility, .detailOnly)

        columns.toggleSidebar()
        columns.worksheetClosed()
        XCTAssertEqual(columns.visibility, .all, "Back still restores what the library showed")
    }

    func testRepeatedOpenAndCloseEventsAreIdempotent() {
        var columns = LibraryColumnState()
        columns.sizeClassChanged(to: .regular)

        columns.worksheetOpened()
        columns.worksheetOpened()
        XCTAssertEqual(columns.visibility, .detailOnly)
        columns.worksheetClosed()
        XCTAssertEqual(columns.visibility, .all)

        columns.visibility = .detailOnly
        columns.worksheetClosed()
        XCTAssertEqual(columns.visibility, .detailOnly, "a stray close must not override the current visibility")
    }

    func testCardsWithAndWithoutBadgesHaveTheSameHeight() throws {
        let plain = try Self.record(title: "Synthetic Worksheet 2", paired: false, hasInk: false)
        let teacher = try Self.record(title: "Synthetic Worksheet 1", paired: true, hasInk: false)
        let both = try Self.record(title: "Synthetic Worksheet 3", paired: true, hasInk: true)

        let heights = [plain, teacher, both].map { Self.height(of: WorksheetCard(record: $0, thumbnail: nil)) }
        XCTAssertGreaterThan(heights[0], 0)
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5)
        XCTAssertEqual(heights[0], heights[2], accuracy: 0.5)
    }

    func testBadgeRowPlaceholderIsNotSpokenByVoiceOver() throws {
        let plain = try Self.record(title: "Synthetic Worksheet 2", paired: false, hasInk: false)
        let card = WorksheetCard(record: plain, thumbnail: nil)
        XCTAssertFalse(card.accessibilityLabel.contains("Ink"))
        XCTAssertFalse(card.accessibilityLabel.contains("Has ink"))
    }

    private static func height(of card: WorksheetCard) -> CGFloat {
        let host = UIHostingController(rootView: card.frame(width: 180))
        return host.sizeThatFits(in: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private static func record(title: String, paired: Bool, hasInk: Bool) throws -> DocumentRecord {
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: title + ".pdf")
        let hash = try ContentHash(rawValue: String(repeating: "a", count: 64))
        let paperKey = try PaperKey(rawValue: "synthetic-paper-1")
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil,
                                          paperKey: paperKey, role: .student, title: title)
        let entry = try ManifestEntry(source: source, sha256: hash, size: 1024,
                                      modifiedAt: Date(timeIntervalSince1970: 0), publication: publication)
        return DocumentRecord(source: entry, pageCount: 2, importedAt: Date(timeIntervalSince1970: 0),
                              hasInk: hasInk, status: .current, title: title, isUpdated: false,
                              pairedDocumentID: paired ? UUID() : nil)
    }
}
