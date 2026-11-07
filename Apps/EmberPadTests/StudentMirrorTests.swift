import XCTest
import PDFKit
import PencilKit
import EmberSyncKit
@testable import EmberPad

/// EP-15: rect maths, throttling and bitmap caching for Mirror Presenter Page and Mirror Full Page, plus the
/// Teacher-copy guard in both framings. All data is synthetic.
@MainActor
final class StudentMirrorTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)

    // MARK: Viewport rect maths

    func testSinglePageViewportAtFitWidthIsTheWholePageWidth() throws {
        // A 0.5x layout: the 612 pt page is 306 view points wide, inset 20 from the view's left edge.
        let layout = MirrorPageLayout(pageIndex: 0, viewRect: CGRect(x: 20, y: 10, width: 306, height: 396), pageSize: letter)
        let viewport = try XCTUnwrap(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 346, height: 300), layouts: [layout]))
        XCTAssertEqual(viewport.pages, [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter))])
        assertRect(viewport.visibleRect, CGRect(x: -40, y: -20, width: 692, height: 600))
    }

    func testZoomedViewportIsTheVisibleSliceOfThePage() throws {
        // 2x zoom, scrolled so the view's origin sits at page point (100, 200).
        let layout = MirrorPageLayout(pageIndex: 3, viewRect: CGRect(x: -200, y: -400, width: 1224, height: 1584), pageSize: letter)
        let viewport = try XCTUnwrap(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 400, height: 300), layouts: [layout]))
        assertRect(viewport.visibleRect, CGRect(x: 100, y: 200, width: 200, height: 150))
        XCTAssertEqual(viewport.pages.map(\.pageIndex), [3])
    }

    func testStraddlingViewportPlacesBothPagesInTheFirstPagesSpace() throws {
        // 1x layout, 16 pt gap: page 1 ends at view y 600, page 2 starts at 616.
        let first = MirrorPageLayout(pageIndex: 1, viewRect: CGRect(x: 0, y: -192, width: 612, height: 792), pageSize: letter)
        let second = MirrorPageLayout(pageIndex: 2, viewRect: CGRect(x: 0, y: 616, width: 612, height: 792), pageSize: letter)
        let viewport = try XCTUnwrap(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 612, height: 800), layouts: [second, first]))
        XCTAssertEqual(viewport.pages.map(\.pageIndex), [1, 2])
        assertRect(viewport.visibleRect, CGRect(x: 0, y: 192, width: 612, height: 800))
        assertRect(viewport.pages[0].frame, CGRect(origin: .zero, size: letter))
        assertRect(viewport.pages[1].frame, CGRect(x: 0, y: 808, width: 612, height: 792))
    }

    func testThreeVisiblePagesKeepTheTwoLargest() throws {
        let layouts = [
            MirrorPageLayout(pageIndex: 0, viewRect: CGRect(x: 0, y: -380, width: 306, height: 396), pageSize: letter), // 16 visible
            MirrorPageLayout(pageIndex: 1, viewRect: CGRect(x: 0, y: 24, width: 306, height: 396), pageSize: letter),   // 396 visible
            MirrorPageLayout(pageIndex: 2, viewRect: CGRect(x: 0, y: 428, width: 306, height: 396), pageSize: letter)   // 72 visible
        ]
        let viewport = try XCTUnwrap(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 306, height: 500), layouts: layouts))
        XCTAssertEqual(viewport.pages.map(\.pageIndex), [1, 2])
        assertRect(viewport.pages[1].frame, CGRect(x: 0, y: 808, width: 612, height: 792))
    }

    func testNoVisiblePageMeansNoViewport() {
        let below = MirrorPageLayout(pageIndex: 0, viewRect: CGRect(x: 0, y: 900, width: 612, height: 792), pageSize: letter)
        XCTAssertNil(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 612, height: 800), layouts: [below]))
        XCTAssertNil(MirrorGeometry.viewport(viewBounds: .zero, layouts: [below]))
        let degenerate = MirrorPageLayout(pageIndex: 0, viewRect: CGRect(x: 0, y: 0, width: 0, height: 10), pageSize: letter)
        XCTAssertNil(MirrorGeometry.viewport(viewBounds: CGRect(x: 0, y: 0, width: 10, height: 10), layouts: [degenerate]))
    }

    func testAspectFitLetterboxesAndPillarboxes() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A landscape iPad viewport nearly fills a 16:10 display.
        assertRect(MirrorGeometry.aspectFit(CGSize(width: 1180, height: 760), in: display),
                   CGRect(x: 21.31578947, y: 0, width: 1397.36842105, height: 900))
        // A portrait page is pillarboxed.
        assertRect(MirrorGeometry.aspectFit(letter, in: display), CGRect(x: 372.27272727, y: 0, width: 695.45454545, height: 900))
        XCTAssertEqual(MirrorGeometry.aspectFit(.zero, in: display), .zero)
    }

    func testFullPageKeepsAOnePercentMargin() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = MirrorGeometry.aspectFit(letter, in: display, margin: MirrorGeometry.fullPageMargin)
        XCTAssertEqual(fitted.minY, 9, accuracy: 0.0001)
        XCTAssertEqual(fitted.maxY, 891, accuracy: 0.0001)
        XCTAssertEqual(fitted.midX, 720, accuracy: 0.0001)
        XCTAssertEqual(fitted.width / fitted.height, letter.width / letter.height, accuracy: 0.0001)
    }

    func testMapPlacesStraddledPagesOnTheDisplay() {
        let visible = CGRect(x: 0, y: 192, width: 612, height: 800)
        let target = CGRect(x: 100, y: 0, width: 306, height: 400)
        assertRect(MirrorGeometry.map(CGRect(origin: .zero, size: letter), from: visible, to: target), CGRect(x: 100, y: -96, width: 306, height: 396))
        assertRect(MirrorGeometry.map(CGRect(x: 0, y: 808, width: 612, height: 792), from: visible, to: target),
                   CGRect(x: 100, y: 308, width: 306, height: 396))
    }

    func testRasterScaleIsBucketedAndCapped() {
        // Small scroll and zoom changes inside a bucket reuse one bitmap scale.
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: letter, displayedPoints: 400, screenScale: 2), 2)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: letter, displayedPoints: 600, screenScale: 2), 2)
        let small = CGSize(width: 200, height: 250)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: small, displayedPoints: 500, screenScale: 2), 8)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: small, displayedPoints: 700, screenScale: 2), 8)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: letter, displayedPoints: 300, screenScale: 1), 0.5)
        // Deep zoom stops at the memory cap: 792 pt × scale ≤ 2560 px.
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: letter, displayedPoints: 20_000, screenScale: 2), 2560.0 / 792.0, accuracy: 0.0001)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: letter, displayedPoints: 700, screenScale: 2), 2560.0 / 792.0, accuracy: 0.0001)
        XCTAssertEqual(MirrorGeometry.rasterScale(pageSize: .zero, displayedPoints: 600, screenScale: 2), 1)
    }

    // MARK: Throttle

    func testThrottleFiresAtMostThirtyTimesASecond() {
        var clock: TimeInterval = 0
        var queued: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var fires: [TimeInterval] = []
        let throttle = MirrorThrottle(now: { clock }, schedule: { delay, work in queued.append((clock + delay, work)) }) {
            fires.append(clock)
        }
        func runQueued(through time: TimeInterval) {
            while let next = queued.first, next.at <= time {
                queued.removeFirst()
                clock = next.at
                next.work()
            }
        }
        // A 120 Hz scroll for one second.
        for step in 0..<120 {
            let time = Double(step) / 120
            runQueued(through: time)
            clock = time
            throttle.signal()
        }
        runQueued(through: .infinity)
        XCTAssertLessThanOrEqual(fires.count, 31)
        XCTAssertGreaterThanOrEqual(fires.count, 29)
        for (earlier, later) in zip(fires, fires.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, MirrorThrottle.studentViewInterval - 1e-9)
        }
    }

    func testThrottleFiresTheFirstSignalAtOnceAndKeepsTheLastPosition() {
        var clock: TimeInterval = 10
        var queued: [@MainActor () -> Void] = []
        var fires = 0
        let throttle = MirrorThrottle(now: { clock }, schedule: { _, work in queued.append(work) }) { fires += 1 }
        throttle.signal()
        XCTAssertEqual(fires, 1, "The first signal is not delayed")
        clock += 0.005; throttle.signal()
        clock += 0.005; throttle.signal()
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(queued.count, 1, "A burst collapses into one trailing fire")
        clock += 0.03; queued.removeFirst()()
        XCTAssertEqual(fires, 2, "The trailing fire publishes the final position")
        clock += 1; throttle.signal()
        XCTAssertEqual(fires, 3, "An idle gap fires immediately again")
    }

    func testCancelledThrottleDropsItsTrailingFire() {
        var clock: TimeInterval = 0
        var queued: [@MainActor () -> Void] = []
        var fires = 0
        let throttle = MirrorThrottle(now: { clock }, schedule: { _, work in queued.append(work) }) { fires += 1 }
        throttle.signal()
        clock += 0.01; throttle.signal()
        throttle.cancel()
        clock += 0.05; queued.removeFirst()()
        XCTAssertEqual(fires, 1)
    }

    // MARK: Bitmap cache

    func testCacheRasterisesOncePerPageBucketAndInkRevision() {
        let cache = StudentPageImageCache()
        let document = UUID(), session = UUID()
        var made = 0
        func make() -> CGImage? { made += 1; return Self.pixel }
        for _ in 0..<90 { // Three seconds of 30 Hz scroll frames at one zoom bucket.
            _ = cache.image(for: .init(documentID: document, pageIndex: 0, kind: .page, scale: 2), make: make)
            _ = cache.image(for: .init(documentID: document, pageIndex: 0, kind: .ink(session: session, revision: 4), scale: 2), make: make)
        }
        XCTAssertEqual(made, 2)
        _ = cache.image(for: .init(documentID: document, pageIndex: 0, kind: .ink(session: session, revision: 5), scale: 2), make: make)
        _ = cache.image(for: .init(documentID: document, pageIndex: 0, kind: .page, scale: 4), make: make)
        XCTAssertEqual(made, 4, "A new stroke or zoom bucket makes one new bitmap")
        XCTAssertEqual(cache.rasterCount, 4)
    }

    func testCacheDropsTheLeastRecentlyUsedBitmap() {
        let cache = StudentPageImageCache(capacity: 2)
        let document = UUID()
        var made = 0
        func make() -> CGImage? { made += 1; return Self.pixel }
        let keys = (0..<3).map { StudentPageImageCache.Key(documentID: document, pageIndex: $0, kind: .page, scale: 1) }
        _ = cache.image(for: keys[0], make: make)
        _ = cache.image(for: keys[1], make: make)
        _ = cache.image(for: keys[0], make: make) // Touch page 0, so page 1 is the oldest.
        _ = cache.image(for: keys[2], make: make)
        XCTAssertEqual(made, 3)
        _ = cache.image(for: keys[0], make: make)
        XCTAssertEqual(made, 3)
        _ = cache.image(for: keys[1], make: make)
        XCTAssertEqual(made, 4)
    }

    func testRasterisedPageIsUprightAndHonoursTheCropBox() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill(); UIRectFill(CGRect(x: 100, y: 100, width: 50, height: 50))
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let whole = try XCTUnwrap(StudentPageDrawingView.rasterise(page, size: letter, scale: 1))
        XCTAssertEqual(whole.width, 612)
        XCTAssertEqual(whole.height, 792)
        XCTAssertTrue(isRed(whole, x: 125, y: 125), "Top-left content stays at the top left")
        XCTAssertFalse(isRed(whole, x: 125, y: 792 - 125), "The page is not drawn upside down")

        // A crop box starting at PDF point (100, 542) is the UIKit rect (100, 100) to (612, 250).
        page.setBounds(CGRect(x: 100, y: 542, width: 512, height: 150), for: .cropBox)
        let cropped = try XCTUnwrap(StudentPageDrawingView.rasterise(page, size: CGSize(width: 512, height: 150), scale: 1))
        XCTAssertTrue(isRed(cropped, x: 25, y: 25), "The crop box origin maps to the bitmap origin")
        XCTAssertFalse(isRed(cropped, x: 75, y: 75))
    }

    func testRotatedPageIsRasterisedInDisplayedOrientation() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter)).pdfData { context in
            context.beginPage()
            UIColor.red.setFill(); UIRectFill(CGRect(x: 100, y: 100, width: 50, height: 50))
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        page.rotation = 90
        XCTAssertEqual(page.displayedSize, CGSize(width: 792, height: 612))
        let image = try XCTUnwrap(StudentPageDrawingView.rasterise(page, size: page.displayedSize, scale: 1))
        XCTAssertEqual(image.width, 792)
        XCTAssertEqual(image.height, 612)
        // A quarter turn clockwise carries the top-left marker to the top right.
        XCTAssertTrue(isRed(image, x: 792 - 125, y: 125), "The marker follows the page rotation")
        XCTAssertFalse(isRed(image, x: 125, y: 125))
    }

    // MARK: Snapshot and privacy in both framings

    func testSnapshotCarriesTheViewportPagesFromItsOwnSession() throws {
        let student = try makeSession(.student, pages: 3)
        var stroke = PKDrawing()
        stroke.strokes = [Self.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 200))]
        student.update(stroke, page: 2)
        let viewport = StudentViewport(visibleRect: CGRect(x: 0, y: 400, width: 612, height: 800), pages: [
            .init(pageIndex: 1, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 2, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        let snapshot = try StudentPageSnapshot(session: student, pageIndex: 1, canvasSize: letter, viewport: viewport)
        XCTAssertEqual(snapshot.visibleRect, viewport.visibleRect)
        XCTAssertEqual(snapshot.slices.map(\.pageIndex), [1, 2])
        XCTAssertTrue(snapshot.slices[0].page === student.pdf.page(at: 1))
        XCTAssertTrue(snapshot.slices[1].page === student.pdf.page(at: 2))
        XCTAssertEqual(snapshot.slices[1].drawing.strokes.count, 1)
        XCTAssertGreaterThan(snapshot.slices[1].inkRevision, snapshot.slices[0].inkRevision)
        XCTAssertEqual(snapshot.slices[1].frame, viewport.pages[1].frame)
    }

    func testViewportNamingAMissingPageFallsBackToTheFocusedPage() throws {
        let student = try makeSession(.student, pages: 2)
        let viewport = StudentViewport(visibleRect: CGRect(origin: .zero, size: letter), pages: [
            .init(pageIndex: 1, frame: CGRect(origin: .zero, size: letter)),
            .init(pageIndex: 7, frame: CGRect(x: 0, y: 808, width: 612, height: 792))
        ])
        let snapshot = try StudentPageSnapshot(session: student, pageIndex: 1, canvasSize: letter, viewport: viewport)
        XCTAssertNil(snapshot.visibleRect)
        XCTAssertTrue(snapshot.slices.isEmpty)
        XCTAssertEqual(snapshot.pageIndex, 1)
    }

    func testTeacherCopyNeverReachesTheStudentViewInEitherFraming() throws {
        let teacher = try makeSession(.teacher, pages: 2)
        let viewport = StudentViewport(visibleRect: CGRect(origin: .zero, size: letter), pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter))])
        XCTAssertThrowsError(try StudentPageSnapshot(session: teacher, pageIndex: 0, canvasSize: letter, viewport: viewport)) { error in
            XCTAssertEqual(error as? StudentViewError, .teacherCopyIsPrivate)
        }
        let state = PresentationState()
        for framing in StudentFraming.allCases {
            state.studentFraming = framing
            XCTAssertEqual(state.student.framing, framing)
            state.student.publish(session: teacher, pageIndex: 0, canvasSize: letter, viewport: viewport)
            XCTAssertNil(state.student.snapshot)
            guard case .teacherCopyPrivate = state.student.content else { return XCTFail("Expected the private placeholder in \(framing)") }
        }
    }

    func testStudentViewDefaultsToPresenterFraming() {
        let state = PresentationState()
        XCTAssertEqual(state.studentFraming, .presenterPage)
        XCTAssertEqual(state.student.framing, .presenterPage)
        XCTAssertEqual(StudentFraming.allCases.map(\.title), ["Mirror Presenter Page (follow my view)", "Mirror Full Page"])
    }

    func testRepublishingAnUnchangedViewportIsSkipped() throws {
        let student = try makeSession(.student, pages: 2)
        let model = StudentDisplayModel()
        let viewport = StudentViewport(visibleRect: CGRect(x: 0, y: 10, width: 612, height: 500), pages: [.init(pageIndex: 0, frame: CGRect(origin: .zero, size: letter))])
        var changes = 0
        let watcher = model.objectWillChange.sink { changes += 1 }
        defer { watcher.cancel() }
        model.publish(session: student, pageIndex: 0, canvasSize: letter, viewport: viewport)
        model.publish(session: student, pageIndex: 0, canvasSize: letter, viewport: viewport)
        XCTAssertEqual(changes, 1)
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: StudentViewport(visibleRect: CGRect(x: 0, y: 20, width: 612, height: 500), pages: viewport.pages))
        XCTAssertEqual(changes, 2, "A scrolled viewport is published")
        var drawing = PKDrawing()
        drawing.strokes = [Self.stroke(from: .zero, to: CGPoint(x: 50, y: 50))]
        student.update(drawing, page: 0)
        model.publish(session: student, pageIndex: 0, canvasSize: letter,
                      viewport: StudentViewport(visibleRect: CGRect(x: 0, y: 20, width: 612, height: 500), pages: viewport.pages))
        XCTAssertEqual(changes, 3, "New ink is published")
    }

    // MARK: Helpers

    private static let pixel: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage

    static func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
        let points = (0...10).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 10
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                                 timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4), opacity: 1,
                                 force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }

    private func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (a, e) in [(actual.minX, expected.minX), (actual.minY, expected.minY), (actual.width, expected.width), (actual.height, expected.height)] {
            XCTAssertEqual(a, e, accuracy: 0.0001, "\(actual) is not \(expected)", file: file, line: line)
        }
    }

    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func makeSession(_ role: DocumentRole, pages: Int) throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep15-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return try StudentMirrorFixture.session(role, pages: pages, root: root)
    }
}

/// Synthetic worksheet sessions for EP-15 tests and screenshots. No real paper, student or class appears.
@MainActor
enum StudentMirrorFixture {
    static let pageSize = CGSize(width: 612, height: 792)

    static func session(_ role: DocumentRole, pages: Int, root: URL) throws -> DocumentSession {
        let store = try LibraryStore(root: root)
        let data = worksheetPDF(pages: pages, role: role)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic-mirror"),
                                          role: role, title: "Synthetic Mirror Worksheet (\(role.rawValue))")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "mirror-\(role.rawValue).pdf"),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                      publication: publication)
        let record = DocumentRecord(source: entry, pageCount: pdf.pageCount, importedAt: Date(timeIntervalSince1970: 0))
        return DocumentSession(record: record, pdf: pdf, originalURL: root.appendingPathComponent("mirror-\(role.rawValue).pdf"),
                               drawings: [:], store: store)
    }

    /// A plain synthetic worksheet: a header, numbered question lines and ruled answer space on every page.
    static func worksheetPDF(pages: Int, role: DocumentRole) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
            for page in 0..<pages {
                context.beginPage()
                let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.black]
                let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray]
                let heading = role == .teacher ? "Synthetic worksheet · TEACHER COPY" : "Synthetic worksheet"
                (heading as NSString).draw(at: CGPoint(x: 48, y: 40), withAttributes: title)
                ("Page \(page + 1) of \(pages)" as NSString).draw(at: CGPoint(x: 470, y: 46), withAttributes: body)
                UIColor.lightGray.setFill(); UIRectFill(CGRect(x: 48, y: 72, width: 516, height: 1))
                for question in 0..<3 {
                    let top = 100 + CGFloat(question) * 220
                    ("Q\(page * 3 + question + 1). Synthetic question text for the mirror test." as NSString)
                        .draw(at: CGPoint(x: 48, y: top), withAttributes: body)
                    UIColor(white: 0.85, alpha: 1).setFill()
                    for rule in 1...6 { UIRectFill(CGRect(x: 48, y: top + CGFloat(rule) * 28, width: 516, height: 0.75)) }
                }
            }
        }
    }
}
