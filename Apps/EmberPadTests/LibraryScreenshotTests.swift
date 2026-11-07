import SwiftUI
import XCTest
import UIKit
import EmberSyncKit
@testable import EmberPad

@MainActor
final class LibraryScreenshotTests: XCTestCase {
    func testCompactSidebarSelectionShowsDetailGrid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "worksheet.pdf")
        _ = try await store.importPDF(data: DeviceChecksTestPDF.data(), source: source, pageCount: 2)
        let library = LibraryController(store: store, inbox: inbox)
        await library.refresh()
        let thumbnails = ThumbnailCache(store: store)
        for document in library.documents { await thumbnails.thumbnail(for: document) }

        for scheme: ColorScheme in [.light, .dark] {
            attach(try await render(library, scheme: scheme, expiry: Date().addingTimeInterval(30 * 86_400),
                                   thumbnails: thumbnails), named: "library-normal-\(scheme.label)")
            let portrait = try await render(library, scheme: scheme, expiry: Date().addingTimeInterval(30 * 86_400),
                                            thumbnails: thumbnails, width: 390, height: 844,
                                            selection: .subject("Synthetic Class"))
            XCTAssertEqual(library.selectedSubject, "Synthetic Class")
            XCTAssertEqual(library.visibleCards.map(\.id), library.documents.map(\.id))
            attach(portrait, named: "library-portrait-\(scheme.label)")
        }
    }

    func testRealLibraryViewStatesRenderWithSyntheticDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: libraryRoot)
        let source = try SourcePath(classFolder: "Synthetic Class", relativePath: "worksheet.pdf")
        _ = try await store.importPDF(data: DeviceChecksTestPDF.data(), source: source, pageCount: 2)
        let library = LibraryController(store: store, inbox: inbox)
        await library.refresh()
        let thumbnails = ThumbnailCache(store: store)
        for document in library.documents { await thumbnails.thumbnail(for: document) }

        let archivedRoot = root.appendingPathComponent("ArchivedLibrary", isDirectory: true)
        let archivedStore = try LibraryStore(root: archivedRoot)
        let archivedSource = try SourcePath(classFolder: "Synthetic Class", relativePath: "archived-worksheet.pdf")
        let archivedRecord = try await archivedStore.importPDF(data: DeviceChecksTestPDF.data(), source: archivedSource, pageCount: 2)
        try await archivedStore.archive(documentID: archivedRecord.id)
        let archivedLibrary = LibraryController(store: archivedStore, inbox: inbox)
        await archivedLibrary.refresh()
        archivedLibrary.sidebarSelection = .archived
        let archivedThumbnails = ThumbnailCache(store: archivedStore)
        for document in archivedLibrary.documents { await archivedThumbnails.thumbnail(for: document) }

        let errorRoot = root.appendingPathComponent("ErrorLibrary", isDirectory: true)
        let errorStore = try LibraryStore(root: errorRoot)
        let invalidPDF = root.appendingPathComponent("synthetic-invalid.pdf")
        try Data("synthetic invalid PDF".utf8).write(to: invalidPDF)
        let errorLibrary = LibraryController(store: errorStore, inbox: inbox)
        await errorLibrary.importFiles([invalidPDF], className: "Synthetic Class")
        XCTAssertTrue(errorLibrary.canRetryError)

        for scheme: ColorScheme in [.light, .dark] {
            let validExpiry = Date().addingTimeInterval(30 * 86_400)
            attach(try await render(library, scheme: scheme, expiry: validExpiry, thumbnails: thumbnails), named: "library-normal-\(scheme.label)")
            let compactImage = try await render(library, scheme: scheme, expiry: validExpiry, thumbnails: thumbnails,
                                                width: 390, height: 844, selection: .subject("Synthetic Class"))
            XCTAssertEqual(library.selectedSubject, "Synthetic Class")
            XCTAssertEqual(library.visibleCards.count, 1)
            attach(compactImage, named: "library-portrait-\(scheme.label)")
            attach(try await render(library, scheme: scheme, expiry: Date().addingTimeInterval(36 * 3_600), thumbnails: thumbnails),
                   named: "library-signing-amber-\(scheme.label)")
            attach(try await render(library, scheme: scheme, expiry: Date().addingTimeInterval(12 * 3_600), thumbnails: thumbnails),
                   named: "library-signing-red-\(scheme.label)")
            attach(try await render(library, scheme: scheme, expiry: nil, thumbnails: thumbnails), named: "library-signing-unknown-\(scheme.label)")

            attach(try await render(errorLibrary, scheme: scheme, expiry: validExpiry), named: "library-error-\(scheme.label)")

            let presentation = PresentationState()
            presentation.externalSceneCount = 1
            attach(try await render(library, scheme: scheme, expiry: validExpiry, presentation: presentation, thumbnails: thumbnails),
                   named: "library-sharing-\(scheme.label)")

            attach(try await render(archivedLibrary, scheme: scheme, expiry: validExpiry, thumbnails: archivedThumbnails),
                   named: "library-archived-\(scheme.label)")

            let emptyStore = try LibraryStore(root: root.appendingPathComponent("Empty-\(scheme.label)", isDirectory: true))
            let emptyLibrary = LibraryController(store: emptyStore, inbox: inbox)
            attach(try await render(emptyLibrary, scheme: scheme, expiry: validExpiry), named: "library-empty-\(scheme.label)")

            let importingRoot = root.appendingPathComponent("Importing-\(scheme.label)", isDirectory: true)
            let importingStore = try LibraryStore(root: importingRoot)
            let importingLibrary = LibraryController(store: importingStore, inbox: inbox)
            let fixtures = root.appendingPathComponent("Fixtures-\(scheme.label)", isDirectory: true)
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            let pdf = DeviceChecksTestPDF.data()
            let urls = try (0..<120).map { index -> URL in
                let url = fixtures.appendingPathComponent("synthetic-\(index).pdf")
                try pdf.write(to: url)
                return url
            }
            let importTask = Task { await importingLibrary.importFiles(urls, className: "Synthetic Class") }
            while !importingLibrary.isImporting { await Task.yield() }
            attach(try await render(importingLibrary, scheme: scheme, expiry: validExpiry),
                   named: "library-importing-\(scheme.label)")
            await importTask.value
        }
    }

    private func render(_ library: LibraryController, scheme: ColorScheme, expiry: Date?,
                        presentation: PresentationState? = nil,
                        thumbnails: ThumbnailCache? = nil,
                        width: CGFloat = 1024, height: CGFloat = 768,
                        selection: LibrarySidebarSelection? = nil) async throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let hosting = UIHostingController(rootView: LibraryView(
            library: library,
            presentation: presentation ?? PresentationState(),
            pairing: PairingController(),
            sync: SyncClient(library: library,
                             folder: LibrarySyncFolder(root: FileManager.default.temporaryDirectory
                                 .appendingPathComponent("EmberPadShotSync-" + UUID().uuidString, isDirectory: true)),
                             credential: { nil }, defaults: UserDefaults(suiteName: "EmberPadShot-" + UUID().uuidString)!),
            signingExpiryDate: expiry,
            thumbnailCache: thumbnails
        ).environment(\.colorScheme, scheme)
            .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: bounds)
        }
        window.frame = bounds
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        if let selection {
            library.sidebarSelection = selection
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(80))
        hosting.view.layoutIfNeeded()

        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            didDraw = hosting.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        XCTAssertTrue(didDraw)
        return image
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension ColorScheme {
    var label: String { self == .light ? "light" : "dark" }
}
