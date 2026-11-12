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

    // MARK: Slide Over swipe (EP95): the hide/show state machine

    private func release(_ side: TeacherCopyPanelSide, open: Bool = true, by translation: CGFloat, velocity: CGFloat = 0,
                         in container: CGSize? = nil) -> TeacherCopyPanelRelease {
        let container = container ?? landscape
        return TeacherCopySlide.release(side: side, isOpen: open, translation: translation, velocity: velocity,
                                        panelSize: TeacherCopyCardGeometry.size(in: container), in: container)
    }

    func testThePanelFollowsTheFingerAndCanLeaveEitherEdgeButNoFurther() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopySlide.x(side: .trailing, isOpen: true, translation: 100, panelSize: size, in: landscape),
                       1180 - 380 - 16 + 100)
        XCTAssertEqual(TeacherCopySlide.x(side: .trailing, isOpen: true, translation: 9000, panelSize: size, in: landscape), 1180)
        XCTAssertEqual(TeacherCopySlide.x(side: .leading, isOpen: true, translation: -9000, panelSize: size, in: landscape), -380)
        // Hidden, it rests fully off its edge, and a swipe in from the tab brings it out with the finger.
        XCTAssertEqual(TeacherCopySlide.x(side: .trailing, isOpen: false, translation: 0, panelSize: size, in: landscape), 1180)
        XCTAssertEqual(TeacherCopySlide.x(side: .leading, isOpen: false, translation: 0, panelSize: size, in: landscape), -380)
        XCTAssertEqual(TeacherCopySlide.x(side: .trailing, isOpen: false, translation: -150, panelSize: size, in: landscape), 1030)
        XCTAssertEqual(TeacherCopySlide.x(side: .trailing, isOpen: false, translation: 200, panelSize: size, in: landscape), 1180,
                       "Pushing the tab outwards cannot take the panel further off")
    }

    func testThePullTabLeadsThePanelInFromItsEdge() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        let tab = TeacherCopyCardGeometry.tabSize.width
        XCTAssertEqual(TeacherCopySlide.tabX(side: .trailing, panelX: 1180, panelSize: size), 1180 - tab, "Flush with the right edge")
        XCTAssertEqual(TeacherCopySlide.tabX(side: .leading, panelX: -380, panelSize: size), 0, "Flush with the left edge")
        XCTAssertEqual(TeacherCopySlide.tabX(side: .trailing, panelX: 1030, panelSize: size), 1030 - tab)
    }

    func testASlowSwipeMoreThanHalfOffItsEdgeHidesItAndLessSpringsBack() {
        for container in [landscape, portrait] {
            for side in TeacherCopyPanelSide.allCases {
                XCTAssertEqual(release(side, by: 260 * side.outward, in: container), .hide(side))
                XCTAssertEqual(release(side, by: 80 * side.outward, in: container), .dock(side), "A short swipe springs back")
            }
        }
    }

    func testAFlickTowardsItsEdgeHidesItWhateverTheDistance() {
        for side in TeacherCopyPanelSide.allCases {
            XCTAssertEqual(release(side, by: 20 * side.outward, velocity: 900 * side.outward), .hide(side))
            XCTAssertEqual(release(side, by: 20 * side.outward, velocity: 300 * side.outward), .dock(side), "Too slow to be a flick")
        }
    }

    func testSwipingAcrossTheMiddleMovesItToTheOtherSide() {
        XCTAssertEqual(release(.trailing, by: -700), .dock(.leading))
        XCTAssertEqual(release(.leading, by: 700), .dock(.trailing))
        XCTAssertEqual(release(.trailing, by: -200), .dock(.trailing))
        XCTAssertEqual(release(.trailing, by: -800, velocity: -900), .hide(.leading),
                       "Carried on off the far edge, it hides there and remembers that side")
    }

    func testTheTabShowsThePanelBySwipeOrFlickAndAWeakPullLeavesItHidden() {
        for side in TeacherCopyPanelSide.allCases {
            let inward = -side.outward
            XCTAssertEqual(release(side, open: false, by: 250 * inward), .dock(side), "Pulled most of the way out")
            XCTAssertEqual(release(side, open: false, by: 40 * inward, velocity: 800 * inward), .dock(side), "A flick in")
            XCTAssertEqual(release(side, open: false, by: 60 * inward), .hide(side), "A short slow pull slides back off")
            XCTAssertEqual(release(side, open: false, by: 30 * side.outward), .hide(side), "Outwards does nothing")
        }
    }

    func testReleasesComeToRestAtTheDockOrFullyOffTheEdge() {
        let size = TeacherCopyCardGeometry.size(in: landscape)
        XCTAssertEqual(TeacherCopySlide.targetX(.dock(.trailing), panelSize: size, in: landscape), 1180 - 380 - 16)
        XCTAssertEqual(TeacherCopySlide.targetX(.dock(.leading), panelSize: size, in: landscape), 16)
        XCTAssertEqual(TeacherCopySlide.targetX(.hide(.trailing), panelSize: size, in: landscape), 1180)
        XCTAssertEqual(TeacherCopySlide.targetX(.hide(.leading), panelSize: size, in: landscape), -380)
    }

    func testTheSpringCarriesOnTheFingersSpeedAndReduceMotionHasNoBounce() {
        XCTAssertEqual(TeacherCopySlide.settle(fromX: 900, toX: 1180, velocity: 1400, reduceMotion: false), .spring(initialVelocity: 5))
        XCTAssertEqual(TeacherCopySlide.settle(fromX: 900, toX: 1180, velocity: -500, reduceMotion: false), .spring(initialVelocity: 0),
                       "Moving away from the target starts the spring from rest")
        XCTAssertEqual(TeacherCopySlide.settle(fromX: 1170, toX: 1180, velocity: 9000, reduceMotion: false), .spring(initialVelocity: 12),
                       "Capped, so a last-moment flick cannot overshoot wildly")
        XCTAssertEqual(TeacherCopySlide.settle(fromX: 900, toX: 1180, velocity: 1400, reduceMotion: true), .ease)
    }

    func testOnlyASidewaysSwipeIsThePanelsSoTheAnswersStillScroll() {
        XCTAssertNil(TeacherCopySlide.beginsSlide(dx: 6, dy: 2), "Undecided inside the slop")
        XCTAssertEqual(TeacherCopySlide.beginsSlide(dx: 14, dy: 4), true)
        XCTAssertEqual(TeacherCopySlide.beginsSlide(dx: -14, dy: 4), true)
        XCTAssertEqual(TeacherCopySlide.beginsSlide(dx: 4, dy: 14), false, "Vertical is the PDF's scroll")
        XCTAssertEqual(TeacherCopySlide.beginsSlide(dx: 8, dy: 8), false)
        // A zoomed-in PDF keeps a sideways swipe while it can still scroll that way; at its edge the panel takes it.
        XCTAssertTrue(TeacherCopySlide.scrollViewTakesSwipe(dx: 20, offsetX: 50, minX: 0, maxX: 300))
        XCTAssertFalse(TeacherCopySlide.scrollViewTakesSwipe(dx: 20, offsetX: 0, minX: 0, maxX: 300))
        XCTAssertFalse(TeacherCopySlide.scrollViewTakesSwipe(dx: -20, offsetX: 300, minX: 0, maxX: 300))
        XCTAssertFalse(TeacherCopySlide.scrollViewTakesSwipe(dx: 20, offsetX: 0, minX: 0, maxX: 0), "Fit to width scrolls only vertically")
    }

    func testTheSwipeIsFingerOnlySoApplePencilNeverMovesThePanel() {
        let recognizer = SlideOverSwipeRecognizer()
        XCTAssertEqual(recognizer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertFalse(recognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)))
        XCTAssertFalse(recognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)))
    }

    func testTheSwipeOnlyHoldsBackScrollingInsideThePanel() {
        let panel = UIView(), inside = UIScrollView(), outside = UIScrollView()
        panel.addSubview(inside)
        let recognizer = SlideOverSwipeRecognizer()
        panel.addGestureRecognizer(recognizer)
        XCTAssertTrue(recognizer.shouldBeRequiredToFail(by: inside.panGestureRecognizer))
        XCTAssertFalse(recognizer.shouldBeRequiredToFail(by: outside.panGestureRecognizer), "The worksheet's canvas never waits for it")
        XCTAssertFalse(recognizer.shouldBeRequiredToFail(by: UITapGestureRecognizer()))
    }

    func testTheSwipeCoversTheWholePanelIncludingThePDF() throws {
        let url = try writeSyntheticTeacherPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 380, height: 520)
        let surface = SlideOverSurface(onChanged: { _ in }, onEnded: { _, _ in }) {
            TeacherCopyCard(content: .pdf(url), documentTitle: "Synthetic Worksheet 1", onClose: {})
        }.frame(width: size.width, height: size.height)
        let (window, controller) = host(surface, size: size, scheme: .light)
        defer { window.isHidden = true }
        let pdf = try XCTUnwrap(firstView(PDFView.self, in: controller.view))
        let owners = sequence(first: pdf as UIView, next: \.superview)
            .flatMap { $0.gestureRecognizers ?? [] }.filter { $0 is SlideOverSwipeRecognizer }
        XCTAssertEqual(owners.count, 1, "A touch on the answers reaches exactly one panel swipe")
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
        let defaults = freshDefaults()
        let card = TeacherCopyCardState(defaults: defaults)
        card.worksheetOpened(hasTeacherCopy: true)
        card.apply(.hide(.trailing))
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.side, .trailing, "Hiding keeps the side, so the pull tab stays on that edge")
        card.apply(.hide(.leading))
        XCTAssertFalse(card.isOpen)
        XCTAssertEqual(card.side, .leading, "Slid off the other edge, the tab moves there")
        let relaunched = TeacherCopyCardState(defaults: defaults)
        XCTAssertEqual(relaunched.side, .leading, "Position memory survives relaunch")
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
        let shown = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 1, mainSceneActive: true)
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
        let shown = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 1, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: shown, mainSceneActive: true, privateAnswerURL: url), .pdf(url))
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: shown, mainSceneActive: true, privateAnswerURL: nil), .noTeacherCopy)

        let mirrored = PresentationPolicy(otherDisplayAttached: true, externalSceneCount: 0, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: mirrored, mainSceneActive: true, privateAnswerURL: url), .hidden(.capture))

        // The iPad's own Screen Recording attaches no screen: the answers show (EP54).
        let recording = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 0, mainSceneActive: true)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: recording, mainSceneActive: true, privateAnswerURL: url), .pdf(url))

        let inactive = PresentationPolicy(otherDisplayAttached: false, externalSceneCount: 1, mainSceneActive: false)
        XCTAssertEqual(TeacherCopyCardContent.resolve(policy: inactive, mainSceneActive: false, privateAnswerURL: url), .hidden(.inactive))
    }

    /// Whenever the policy hides private content, no input can make the card carry the answers' URL, so the
    /// body never builds a PDF view and no answer pixels are produced.
    func testHiddenPolicyNeverYieldsAPDFForAnyInput() {
        let url = URL(fileURLWithPath: "/tmp/synthetic-teacher.pdf")
        for display in [false, true] {
            for external in [0, 1, 2] {
                for active in [false, true] {
                    let policy = PresentationPolicy(otherDisplayAttached: display, externalSceneCount: external, mainSceneActive: active)
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
                       "Something is copying the whole iPad screen (not AirPlay to Ember Slate's student view).")
        XCTAssertEqual(TeacherCopyCardContent.HiddenReason.inactive.text, "Hidden while Ember Slate isn't the active app.")
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

    // MARK: Slide Over in the real overlay (EP95 frame strip)

    /// Drives the real overlay over a synthetic worksheet the way a finger does: the panel follows the swipe off the
    /// right edge, a flick hides it (and it leaves the hierarchy), then a swipe on the pull tab brings it back out of the
    /// edge with the finger. Frames go to `EP95_SHOTS_DIR` (`TEST_RUNNER_EP95_SHOTS_DIR`), else the temporary directory.
    func testSwipingThePanelOffAndBackInFollowsTheFinger() throws {
        let url = try writeSyntheticTeacherPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let card = TeacherCopyCardState(defaults: freshDefaults())
        card.dock(.trailing)
        let worksheet = SyntheticWorksheetBody(content: .pdf(url), title: "Synthetic Worksheet 1", card: card)
            .frame(width: landscape.width, height: landscape.height)
        let (window, controller) = host(worksheet, size: landscape, scheme: .light)
        defer { window.isHidden = true }
        var frames: [UIImage] = []
        func frame(after seconds: TimeInterval = 0.04) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
            frames.append(snapshot(of: controller.view))
        }
        func swipe(_ recognizer: SlideOverSwipeRecognizer, through travel: [CGFloat], velocity: CGFloat) {
            for translation in travel {
                recognizer.onSwipe(.changed(translation))
                frame()
            }
            recognizer.onSwipe(.ended(travel.last ?? 0, velocity: velocity))
            for _ in 0..<6 { frame() }
            frame(after: 0.8)
        }

        frame()
        let panelSwipe = try XCTUnwrap(swipeRecognizers(in: controller.view).first { findPDFView(in: $0.view!) },
                                       "The swipe sits over the answers themselves")
        swipe(panelSwipe, through: [40, 100, 160, 220], velocity: 900)
        XCTAssertFalse(card.isOpen, "A flick towards its edge hides the panel")
        XCTAssertEqual(card.side, .trailing)
        XCTAssertFalse(findPDFView(in: controller.view), "Once off screen the hidden panel leaves the hierarchy")

        let tabSwipe = try XCTUnwrap(swipeRecognizers(in: controller.view).first, "Only the pull tab is left")
        swipe(tabSwipe, through: [-40, -120, -200, -280], velocity: -800)
        XCTAssertTrue(card.isOpen, "Swiping the tab in brings the panel back")
        XCTAssertEqual(card.side, .trailing)
        XCTAssertTrue(findPDFView(in: controller.view))

        let directory = ProcessInfo.processInfo.environment["EP95_SHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, image) in frames.enumerated() {
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(String(format: "slide-%02d.png", index)))
        }
    }

    // MARK: Helpers

    private func swipeRecognizers(in view: UIView) -> [SlideOverSwipeRecognizer] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? SlideOverSwipeRecognizer }
            + view.subviews.flatMap { swipeRecognizers(in: $0) }
    }

    private func snapshot(of view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

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

    private func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.firstView(type, in: $0) }.first
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
        let card = TeacherCopyCardState(defaults: UserDefaults(suiteName: "SyntheticWorksheetBody-\(UUID().uuidString)")!)
        card.dock(side)
        if !isOpen { card.close() }
        self.init(content: content, title: title, card: card)
    }

    init(content: TeacherCopyCardContent, title: String, card: TeacherCopyCardState) {
        self.content = content
        self.title = title
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
