import SwiftUI
import PDFKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP-13: the floating Teacher copy card. Geometry and state mapping are pure, so they run without a scene;
/// the screenshot test renders every state in light and dark. All data is synthetic.
@MainActor
final class TeacherCopyCardTests: XCTestCase {
    private let landscape = CGSize(width: 1180, height: 700)
    private let portrait = CGSize(width: 820, height: 1000)

    // MARK: Geometry

    func testCardSizeFollowsOrientationAndMinimum() {
        let wide = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(wide.width, 380)
        XCTAssertEqual(wide.height, 700 * 0.66, accuracy: 0.001)
        let tall = TeacherCopyCardGeometry.size(in: portrait)
        XCTAssertEqual(tall.width, 380)
        XCTAssertEqual(tall.height, 1000 * 0.52, accuracy: 0.001)
        // 66% of 500 is 330, below the 360 pt minimum.
        XCTAssertEqual(TeacherCopyCardGeometry.size(in: CGSize(width: 1000, height: 500)).height, 360)
    }

    func testCardNeverExceedsTheBodyMinusItsInset() {
        let tiny = TeacherCopyCardGeometry.size(in: CGSize(width: 300, height: 380))
        XCTAssertLessThanOrEqual(tiny.width, 300 - 32)
        XCTAssertLessThanOrEqual(tiny.height, 380 - 32)
    }

    func testCornersRestSixteenPointsFromTheEdges() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .topLeading, cardSize: size, in: landscape), CGPoint(x: 16, y: 16))
        XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .topTrailing, cardSize: size, in: landscape),
                       CGPoint(x: 1180 - 380 - 16, y: 16))
        XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .bottomLeading, cardSize: size, in: landscape),
                       CGPoint(x: 16, y: 700 - size.height - 16))
        XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .bottomTrailing, cardSize: size, in: landscape),
                       CGPoint(x: 1180 - 380 - 16, y: 700 - size.height - 16))
    }

    func testDraggingIsClampedInsideTheBody() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopyCardGeometry.clamp(CGPoint(x: -500, y: -500), cardSize: size, in: landscape), CGPoint(x: 16, y: 16))
        let far = TeacherCopyCardGeometry.clamp(CGPoint(x: 9000, y: 9000), cardSize: size, in: landscape)
        XCTAssertEqual(far, TeacherCopyCardGeometry.origin(for: .bottomTrailing, cardSize: size, in: landscape))
        let inside = CGPoint(x: 300, y: 100)
        XCTAssertEqual(TeacherCopyCardGeometry.clamp(inside, cardSize: size, in: landscape), inside)
    }

    func testReleaseSnapsToTheNearestCorner() {
        for container in [landscape, portrait] {
            let size = TeacherCopyCardGeometry.size(in: container)
            for corner in TeacherCopyCardCorner.allCases {
                let origin = TeacherCopyCardGeometry.origin(for: corner, cardSize: size, in: container)
                // Released a little off the corner, towards the middle, it returns to the same corner.
                let nudged = CGPoint(x: origin.x + (corner.isTrailing ? -40 : 40), y: origin.y + (corner.isBottom ? -40 : 40))
                XCTAssertEqual(TeacherCopyCardGeometry.nearestCorner(toOrigin: nudged, cardSize: size, in: container), corner)
            }
        }
    }

    func testOrientationComesFromTheBodyShape() {
        XCTAssertEqual(TeacherCopyCardOrientation(containerSize: landscape), .landscape)
        XCTAssertEqual(TeacherCopyCardOrientation(containerSize: portrait), .portrait)
    }

    func testCornerRawValuesAreStableForSceneStorage() {
        XCTAssertEqual(TeacherCopyCardCorner.allCases.map(\.rawValue), ["topLeading", "topTrailing", "bottomLeading", "bottomTrailing"])
        for corner in TeacherCopyCardCorner.allCases { XCTAssertEqual(TeacherCopyCardCorner(rawValue: corner.rawValue), corner) }
    }

    // MARK: States and privacy

    func testContentStates() {
        let url = URL(fileURLWithPath: "/tmp/synthetic-teacher.pdf")
        let shown = PresentationPolicy(captureActive: false, externalSceneCount: 1, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: shown, mainSceneActive: true, privateAnswerURL: url), .pdf(url))
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: shown, mainSceneActive: true, privateAnswerURL: nil), .noTeacherCopy)

        let captured = PresentationPolicy(captureActive: true, externalSceneCount: 0, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: captured, mainSceneActive: true, privateAnswerURL: url), .hidden(.capture))

        let inactive = PresentationPolicy(captureActive: false, externalSceneCount: 1, mainSceneActive: false)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: inactive, mainSceneActive: false, privateAnswerURL: url), .hidden(.inactive))
    }

    /// Whenever the policy hides private content, no input can make the card carry the answers' URL, so the
    /// body never builds a PDF view and no answer pixels are produced.
    func testHiddenPolicyNeverYieldsAPDFForAnyInput() {
        let url = URL(fileURLWithPath: "/tmp/synthetic-teacher.pdf")
        for capture in [false, true] {
            for external in [0, 1, 2] {
                for active in [false, true] {
                    let policy = PresentationPolicy(captureActive: capture, externalSceneCount: external, mainSceneActive: active)
                    for answers in [url, nil] {
                        let content = TeacherCopyCardContent.resolve(policy: policy, mainSceneActive: active, privateAnswerURL: answers)
                        if policy.hidePrivateContent {
                            guard case .hidden = content else { return XCTFail("Expected hidden for \(policy)") }
                        } else if case .hidden = content {
                            XCTFail("Hidden without the policy asking for it: \(policy)")
                        }
                    }
                }
            }
        }
    }

    func testHiddenReasonsUseTheDesignCopy() {
        XCTAssertEqual(TeacherCopyCardContent.HiddenReason.capture.text,
                       "Something is copying the whole iPad screen (not AirPlay to EmberPad's student view).")
        XCTAssertEqual(TeacherCopyCardContent.HiddenReason.inactive.text, "Hidden while EmberPad isn't the active app.")
    }

    /// The card lives in the main scene only. The student display model has no answer location, and a Teacher
    /// record still cannot make a `StudentSafeDocument` (EP-08's gate is unchanged).
    func testStudentViewHasNoAnswerLocationAndTheRoleGateStillHolds() throws {
        let model = StudentDisplayModel()
        XCTAssertNil(model.snapshot)
        let teacher = try record(role: .teacher)
        XCTAssertNil(StudentSafeDocument(teacher))
        XCTAssertNotNil(StudentSafeDocument(try record(role: .student)))
        model.opened(teacher)
        if case .teacherCopyPrivate = model.content {} else { XCTFail("A Teacher copy must show only the private placeholder") }
    }

    func testRendersPDFOnlyForTheOpenStateAndEveryOtherStateDrawsNoAnswers() throws {
        let url = try writeSyntheticTeacherPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 380, height: 520)
        let open = TeacherCopyCardBody(content: .pdf(url)).frame(width: size.width, height: size.height)
        XCTAssertTrue(containsPDFView(open, size: size), "The open state shows the read-only PDF")
        for content in [TeacherCopyCardContent.hidden(.capture), .hidden(.inactive), .noTeacherCopy] {
            let view = TeacherCopyCardBody(content: content).frame(width: size.width, height: size.height)
            XCTAssertFalse(containsPDFView(view, size: size), "\(content) must not build a PDF view")
        }
    }

    // MARK: Screenshots (EP-13 acceptance)

    func testEveryStateRendersLightAndDark() throws {
        let url = try writeSyntheticTeacherPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let title = "Synthetic Worksheet 1"
        let cardSize = CGSize(width: 380, height: 462)
        let states: [(String, TeacherCopyCardContent)] = [
            ("open", .pdf(url)),
            ("answers-hidden-capture", .hidden(.capture)),
            ("answers-hidden-inactive", .hidden(.inactive)),
            ("no-teacher-copy", .noTeacherCopy),
        ]
        for scheme: ColorScheme in [.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            for (name, content) in states {
                let view = TeacherCopyCard(content: content, documentTitle: title, onClose: {})
                    .frame(width: cardSize.width, height: cardSize.height)
                    .padding(40)
                    .background(Theme.canvas)
                try save(snapshot(view, size: CGSize(width: cardSize.width + 80, height: cardSize.height + 80), scheme: scheme),
                         as: "teacher-card-\(name)-\(suffix)")
            }
            let tab = TeacherCopyEdgeTab {}
                .frame(width: 120, height: 200, alignment: .leading)
                .background(Theme.canvas)
            try save(snapshot(tab, size: CGSize(width: 120, height: 200), scheme: scheme), as: "teacher-card-edge-tab-\(suffix)")

            // The card over a synthetic worksheet body, in each orientation and a different corner.
            for (orientationName, container, corner) in [("landscape", landscape, TeacherCopyCardCorner.topLeading),
                                                         ("portrait", portrait, .bottomTrailing)] {
                let worksheet = SyntheticWorksheetBody(
                    content: .pdf(url), title: title, isOpen: true,
                    landscape: orientationName == "landscape" ? corner : .topLeading,
                    portrait: orientationName == "portrait" ? corner : .topLeading)
                    .frame(width: container.width, height: container.height)
                try save(snapshot(worksheet, size: container, scheme: scheme),
                         as: "teacher-card-over-worksheet-\(orientationName)-\(suffix)")
            }
            let closed = SyntheticWorksheetBody(content: .pdf(url), title: title, isOpen: false, landscape: .topLeading, portrait: .topLeading)
                .frame(width: landscape.width, height: landscape.height)
            try save(snapshot(closed, size: landscape, scheme: scheme), as: "teacher-card-closed-edge-tab-\(suffix)")
        }
    }

    // MARK: Helpers

    private func record(role: DocumentRole) throws -> DocumentRecord {
        let data = Data("synthetic".utf8)
        let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: "synthetic-paper"),
                                          role: role, title: "Synthetic Paper (\(role.rawValue))")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                      publication: publication)
        return DocumentRecord(source: entry, pageCount: 2, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func writeSyntheticTeacherPDF() throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22)]
                let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15)]
                "Synthetic answers, page \(page)".draw(at: CGPoint(x: 56, y: 56), withAttributes: heading)
                for line in 0..<14 {
                    "\(line + 1). Synthetic mark scheme line for layout only.".draw(at: CGPoint(x: 56, y: 110 + CGFloat(line) * 28), withAttributes: body)
                }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ep13-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    private func host<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> (UIWindow, UIHostingController<AnyView>) {
        let controller = UIHostingController(rootView: AnyView(view.environment(\.colorScheme, scheme)))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        // Let PDFKit lay out and rasterize its pages before the view is inspected or drawn.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        return (window, controller)
    }

    private func snapshot<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> UIImage {
        let (window, controller) = host(view, size: size, scheme: scheme)
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }

    private func containsPDFView<V: View>(_ view: V, size: CGSize) -> Bool {
        let (window, controller) = host(view, size: size, scheme: .light)
        defer { window.isHidden = true }
        return findPDFView(in: controller.view)
    }

    private func findPDFView(in view: UIView) -> Bool {
        view is PDFView || view.subviews.contains { findPDFView(in: $0) }
    }

    private func save(_ image: UIImage, as name: String) throws {
        XCTAssertGreaterThan(image.size.width, 0)
        let directory = ProcessInfo.processInfo.environment["EP13_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A stand-in for the worksheet body: a synthetic white page on `canvas` with the real overlay on top.
private struct SyntheticWorksheetBody: View {
    let content: TeacherCopyCardContent
    let title: String
    @State var isOpen: Bool
    @State var landscape: TeacherCopyCardCorner
    @State var portrait: TeacherCopyCardCorner

    init(content: TeacherCopyCardContent, title: String, isOpen: Bool, landscape: TeacherCopyCardCorner, portrait: TeacherCopyCardCorner) {
        self.content = content
        self.title = title
        _isOpen = State(initialValue: isOpen)
        _landscape = State(initialValue: landscape)
        _portrait = State(initialValue: portrait)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Synthetic Worksheet 1").font(.system(.title2, design: .serif).weight(.semibold))
                ForEach(1..<12, id: \.self) { line in
                    Text("\(line). Synthetic question text for layout only.").font(.body)
                }
            }
            .foregroundStyle(Color.black)
            .padding(48)
            .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
            .frame(maxWidth: .infinity)
            TeacherCopyCardOverlay(content: content, documentTitle: title, isOpen: $isOpen,
                                   landscapeCorner: $landscape, portraitCorner: $portrait)
        }
    }
}
