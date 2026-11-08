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

    // MARK: Geometry (Slide Over style panel)

    func testPanelIsTallAndDocksInsetAgainstEitherEdge() {
        for container in [landscape, portrait] {
            let size = TeacherCopyCardGeometry.size(in: container)
            XCTAssertEqual(size, CGSize(width: 380, height: container.height - 32))
            XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .leading, panelSize: size, in: container), CGPoint(x: 16, y: 16))
            XCTAssertEqual(TeacherCopyCardGeometry.origin(for: .trailing, panelSize: size, in: container),
                           CGPoint(x: container.width - 380 - 16, y: 16))
        }
    }

    func testPanelNeverExceedsTheBodyMinusItsInset() {
        let tiny = TeacherCopyCardGeometry.size(in: CGSize(width: 300, height: 380))
        XCTAssertLessThanOrEqual(tiny.width, 300 - 32)
        XCTAssertLessThanOrEqual(tiny.height, 380 - 32)
    }

    func testDraggingIsHorizontalAndCanLeaveEitherEdge() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopyCardGeometry.draggedX(side: .trailing, translation: 100, panelSize: size, in: landscape),
                       1180 - 380 - 16 + 100)
        XCTAssertEqual(TeacherCopyCardGeometry.draggedX(side: .trailing, translation: 9000, panelSize: size, in: landscape), 1180)
        XCTAssertEqual(TeacherCopyCardGeometry.draggedX(side: .leading, translation: -9000, panelSize: size, in: landscape), -380)
    }

    func testDraggingOffItsEdgeHidesThePanel() {
        for container in [landscape, portrait] {
            let size = TeacherCopyCardGeometry.size(in: container)
            for side in TeacherCopyPanelSide.allCases {
                let far = 200 * side.outward, near = 60 * side.outward
                XCTAssertEqual(TeacherCopyCardGeometry.release(side: side, translation: far, predictedTranslation: far,
                                                               panelSize: size, in: container), .hide)
                XCTAssertEqual(TeacherCopyCardGeometry.release(side: side, translation: near, predictedTranslation: near,
                                                               panelSize: size, in: container), .dock(side),
                               "A short drag springs back")
                XCTAssertEqual(TeacherCopyCardGeometry.release(side: side, translation: near, predictedTranslation: 400 * side.outward,
                                                               panelSize: size, in: container), .hide, "A flick off the edge hides it")
            }
        }
    }

    func testDraggingAcrossTheMiddleMovesItToTheOtherSide() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopyCardGeometry.release(side: .trailing, translation: -700, predictedTranslation: -750,
                                                       panelSize: size, in: landscape), .dock(.leading))
        XCTAssertEqual(TeacherCopyCardGeometry.release(side: .leading, translation: 700, predictedTranslation: 750,
                                                       panelSize: size, in: landscape), .dock(.trailing))
        XCTAssertEqual(TeacherCopyCardGeometry.release(side: .trailing, translation: -200, predictedTranslation: -220,
                                                       panelSize: size, in: landscape), .dock(.trailing))
    }

    func testDraggingTheGrabberInwardsShowsThePanel() {
        XCTAssertTrue(TeacherCopyCardGeometry.grabberOpens(side: .trailing, translation: -60, predictedTranslation: -60))
        XCTAssertTrue(TeacherCopyCardGeometry.grabberOpens(side: .leading, translation: 60, predictedTranslation: 60))
        XCTAssertTrue(TeacherCopyCardGeometry.grabberOpens(side: .trailing, translation: -20, predictedTranslation: -120), "a flick in")
        XCTAssertFalse(TeacherCopyCardGeometry.grabberOpens(side: .trailing, translation: 60, predictedTranslation: 60), "outwards")
        XCTAssertFalse(TeacherCopyCardGeometry.grabberOpens(side: .leading, translation: 10, predictedTranslation: 20))
    }

    func testSideRawValuesAreStableForPersistence() {
        XCTAssertEqual(TeacherCopyPanelSide.allCases.map(\.rawValue), ["leading", "trailing"])
        XCTAssertEqual(TeacherCopyPanelSide.leading.opposite, .trailing)
    }

    // MARK: Open state and side (persisted, not @SceneStorage)

    func testCloseSetsIsOpenFalseAndTheEdgeTabReopens() {
        let card = TeacherCopyCardState(defaults: freshDefaults())
        card.worksheetOpened(hasTeacherCopy: true)
        XCTAssertTrue(card.isOpen)
        card.close()
        XCTAssertFalse(card.isOpen)
        card.open()
        XCTAssertTrue(card.isOpen)
    }

    func testBookToggleFlipsItsAccessibilityLabel() {
        let card = TeacherCopyCardState(defaults: freshDefaults())
        card.worksheetOpened(hasTeacherCopy: true)
        XCTAssertEqual(card.toggleAccessibilityLabel, "Hide Teacher copy")
        card.toggle()
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.toggleAccessibilityLabel, "Show Teacher copy")
        card.toggle()
        XCTAssertTrue(card.isOpen)
        XCTAssertEqual(card.toggleAccessibilityLabel, "Hide Teacher copy")
    }

    func testOpenStateAndSideSurviveRelaunch() {
        let defaults = freshDefaults()
        let first = TeacherCopyCardState(defaults: defaults)
        XCTAssertEqual(first.side, .trailing, "Docks on the right by default, like Slide Over")
        first.dock(.leading)
        first.close()

        let relaunched = TeacherCopyCardState(defaults: defaults)
        XCTAssertFalse(relaunched.isOpen)
        XCTAssertEqual(relaunched.side, .leading)
        relaunched.worksheetOpened(hasTeacherCopy: true)
        XCTAssertFalse(relaunched.isOpen, "A panel the teacher hid stays hidden on the next worksheet")
    }

    func testReleasingThePanelHidesOrDocksIt() {
        let card = TeacherCopyCardState(defaults: freshDefaults())
        card.worksheetOpened(hasTeacherCopy: true)
        card.apply(.hide)
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.side, .trailing, "Hiding keeps the side, so the grabber stays on that edge")
        card.apply(.dock(.leading))
        XCTAssertTrue(card.isOpen)
        XCTAssertEqual(card.side, .leading)
    }

    func testAWorksheetWithoutATeacherCopyStartsClosedAndKeepsTheRememberedChoice() {
        let defaults = freshDefaults()
        let card = TeacherCopyCardState(defaults: defaults)
        card.worksheetOpened(hasTeacherCopy: false)
        XCTAssertFalse(card.isOpen, "Only the edge tab shows when there is no Teacher copy")
        XCTAssertEqual(card.toggleAccessibilityLabel, "Show Teacher copy")
        card.worksheetOpened(hasTeacherCopy: true)
        XCTAssertTrue(card.isOpen, "The next paired worksheet opens the card again")
    }

    // MARK: Answer key

    func testAPairedWorksheetsCardResolvesToItsTeacherCopyPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ep34-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let student = try await importSynthetic(role: .student, paper: "synthetic-paired", into: store)
        let teacher = try await importSynthetic(role: .teacher, paper: "synthetic-paired", into: store)
        let unpaired = try await importSynthetic(role: .student, paper: "synthetic-unpaired", into: store)
        let library = LibraryController(store: store, inbox: root.appendingPathComponent("Inbox"))

        let pairedRecord = try await store.document(student.id)
        XCTAssertEqual(pairedRecord.pairedDocumentID, teacher.id)
        let resolved = await library.teacherCopyURL(for: pairedRecord)
        let answers = try XCTUnwrap(resolved)
        let teacherOriginal = try await store.originalURL(documentID: teacher.id)
        XCTAssertEqual(answers, teacherOriginal)
        let shown = PresentationPolicy(captureActive: false, externalSceneCount: 1, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: shown, mainSceneActive: true, privateAnswerURL: answers), .pdf(teacherOriginal))

        let unpairedAnswers = await library.teacherCopyURL(for: try await store.document(unpaired.id))
        XCTAssertNil(unpairedAnswers)
        // A Teacher copy's own pairing points at the Student copy, which is never an answer key.
        let teacherAnswers = await library.teacherCopyURL(for: try await store.document(teacher.id))
        XCTAssertNil(teacherAnswers)
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

            // The panel over a synthetic worksheet body, in each orientation and on a different side.
            for (orientationName, container, side) in [("landscape", landscape, TeacherCopyPanelSide.trailing),
                                                       ("portrait", portrait, .leading)] {
                let worksheet = SyntheticWorksheetBody(content: .pdf(url), title: title, isOpen: true, side: side)
                    .frame(width: container.width, height: container.height)
                try save(snapshot(worksheet, size: container, scheme: scheme),
                         as: "teacher-card-over-worksheet-\(orientationName)-\(suffix)")
            }
            let closed = SyntheticWorksheetBody(content: .pdf(url), title: title, isOpen: false, side: .trailing)
                .frame(width: landscape.width, height: landscape.height)
            try save(snapshot(closed, size: landscape, scheme: scheme), as: "teacher-card-closed-edge-tab-\(suffix)")
        }
    }

    // MARK: Helpers

    private func freshDefaults() -> UserDefaults {
        let name = "TeacherCopyCardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func importSynthetic(role: DocumentRole, paper: String, into store: LibraryStore) async throws -> DocumentRecord {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("Synthetic \(paper) \(role.rawValue)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: nil)
        }
        let publication = try Publication(subject: "Synthetic Subject", paperKey: PaperKey(rawValue: paper),
                                          role: role, title: "Synthetic \(paper) (\(role.rawValue))")
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(paper)-\(role.rawValue).pdf"),
                                      sha256: .digest(data), size: Int64(data.count), modifiedAt: Date(timeIntervalSince1970: 0),
                                      publication: publication)
        return try await store.importPDF(data: data, entry: entry, pageCount: 1)
    }

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
    @State var card: TeacherCopyCardState

    init(content: TeacherCopyCardContent, title: String, isOpen: Bool, side: TeacherCopyPanelSide) {
        self.content = content
        self.title = title
        let card = TeacherCopyCardState(defaults: UserDefaults(suiteName: "SyntheticWorksheetBody-\(UUID().uuidString)")!)
        card.dock(side)
        if !isOpen { card.close() }
        _card = State(initialValue: card)
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
            TeacherCopyCardOverlay(content: content, documentTitle: title, card: card)
        }
    }
}
