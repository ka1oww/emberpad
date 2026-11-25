import SwiftUI
import PDFKit
import XCTest
import EmberSyncKit
@testable import EmberPad

/// EP186: the slide-over holding the copy the canvas is not showing. Its geometry, slide, state and content are pure,
/// so they run without a scene. All data is synthetic.
@MainActor
final class CopySlideOverTests: XCTestCase {
    private let landscape = CGSize(width: 1180, height: 700)
    private let portrait = CGSize(width: 820, height: 1000)

    // MARK: Geometry

    func testPanelIsTallAndDocksInsetAgainstEitherEdge() {
        for container in [landscape, portrait] {
            let size = SlideOverGeometry.size(in: container)
            XCTAssertEqual(size, CGSize(width: 380, height: container.height - 32))
            XCTAssertEqual(SlideOverGeometry.origin(for: .leading, panelSize: size, in: container), CGPoint(x: 16, y: 16))
            XCTAssertEqual(SlideOverGeometry.origin(for: .trailing, panelSize: size, in: container),
                           CGPoint(x: container.width - 380 - 16, y: 16))
        }
    }

    func testPanelNeverExceedsTheWorksheetMinusItsInset() {
        let tiny = SlideOverGeometry.size(in: CGSize(width: 300, height: 380))
        XCTAssertLessThanOrEqual(tiny.width, 300 - 32)
        XCTAssertLessThanOrEqual(tiny.height, 380 - 32)
    }

    func testResizingKeepsTheWidthReadableAndLeavesTheWorksheetInReach() {
        XCTAssertEqual(SlideOverGeometry.clampedWidth(100, in: landscape), SlideOverGeometry.minWidth)
        XCTAssertEqual(SlideOverGeometry.clampedWidth(5000, in: landscape), 1180 - 32 - 160)
        XCTAssertEqual(SlideOverGeometry.resizedWidth(from: 380, translation: -60, side: .trailing, in: landscape), 440,
                       "Dragging a right-hand panel's inner edge left widens it")
        XCTAssertEqual(SlideOverGeometry.resizedWidth(from: 380, translation: -60, side: .leading, in: landscape), 320)
    }

    // MARK: Slide

    private func release(_ side: SlideOverSide, by translation: CGFloat, velocity: CGFloat = 0) -> SlideOverRelease {
        SlideOverSlide.release(side: side, isOpen: true, translation: translation, velocity: velocity,
                               panelSize: SlideOverGeometry.size(in: landscape), in: landscape)
    }

    func testClosedItRestsFullyOffItsEdgeWithItsTabFlushAgainstIt() {
        let size = SlideOverGeometry.size(in: landscape)
        XCTAssertEqual(SlideOverSlide.x(side: .trailing, isOpen: false, translation: 0, panelSize: size, in: landscape), 1180)
        XCTAssertEqual(SlideOverSlide.x(side: .leading, isOpen: false, translation: 0, panelSize: size, in: landscape), -380)
        let tab = SlideOverGeometry.tabSize.width
        XCTAssertEqual(SlideOverSlide.tabX(side: .trailing, in: landscape), 1180 - tab)
        XCTAssertEqual(SlideOverSlide.tabX(side: .leading, in: landscape), 0)
    }

    func testTheOpenPanelFollowsTheFingerAndCanLeaveEitherEdgeButNoFurther() {
        let size = SlideOverGeometry.size(in: landscape)
        XCTAssertEqual(SlideOverSlide.x(side: .trailing, isOpen: true, translation: 100, panelSize: size, in: landscape),
                       1180 - 380 - 16 + 100)
        XCTAssertEqual(SlideOverSlide.x(side: .trailing, isOpen: true, translation: 9000, panelSize: size, in: landscape), 1180)
        XCTAssertEqual(SlideOverSlide.x(side: .leading, isOpen: true, translation: -9000, panelSize: size, in: landscape), -380)
    }

    func testASwipeOffItsEdgeClosesItAndAShortOneSpringsBack() {
        for side in SlideOverSide.allCases {
            XCTAssertEqual(release(side, by: 260 * side.outward), .hide(side))
            XCTAssertEqual(release(side, by: 80 * side.outward), .dock(side))
            XCTAssertEqual(release(side, by: 20 * side.outward, velocity: 900 * side.outward), .hide(side), "A flick")
        }
        XCTAssertEqual(release(.trailing, by: -700), .dock(.leading), "Across the middle it moves to the other side")
    }

    func testReleasesComeToRestAtTheDockOrFullyOffTheEdge() {
        let size = SlideOverGeometry.size(in: landscape)
        XCTAssertEqual(SlideOverSlide.targetX(.dock(.trailing), panelSize: size, in: landscape), 1180 - 380 - 16)
        XCTAssertEqual(SlideOverSlide.targetX(.dock(.leading), panelSize: size, in: landscape), 16)
        XCTAssertEqual(SlideOverSlide.targetX(.hide(.trailing), panelSize: size, in: landscape), 1180)
        XCTAssertEqual(SlideOverSlide.targetX(.hide(.leading), panelSize: size, in: landscape), -380)
    }

    func testTheSpringCarriesOnTheFingersSpeedAndReduceMotionHasNoBounce() {
        XCTAssertEqual(SlideOverSlide.settle(fromX: 900, toX: 1180, velocity: 1400, reduceMotion: false), .spring(initialVelocity: 5))
        XCTAssertEqual(SlideOverSlide.settle(fromX: 900, toX: 1180, velocity: -500, reduceMotion: false), .spring(initialVelocity: 0))
        XCTAssertEqual(SlideOverSlide.settle(fromX: 900, toX: 1180, velocity: 1400, reduceMotion: true), .ease)
    }

    func testOnlyASidewaysSwipeIsThePanelsSoItsPagesStillScroll() {
        XCTAssertNil(SlideOverSlide.beginsSlide(dx: 6, dy: 2), "Undecided inside the slop")
        XCTAssertEqual(SlideOverSlide.beginsSlide(dx: 14, dy: 4), true)
        XCTAssertEqual(SlideOverSlide.beginsSlide(dx: 4, dy: 14), false, "Vertical is the PDF's scroll")
        XCTAssertTrue(SlideOverSlide.scrollViewTakesSwipe(dx: 20, offsetX: 50, minX: 0, maxX: 300))
        XCTAssertFalse(SlideOverSlide.scrollViewTakesSwipe(dx: 20, offsetX: 0, minX: 0, maxX: 300))
        XCTAssertFalse(SlideOverSlide.scrollViewTakesSwipe(dx: 20, offsetX: 0, minX: 0, maxX: 0))
    }

    func testTheSwipeIsFingerOnlyAndOnlyHoldsBackScrollingInsideThePanel() {
        let recognizer = SlideOverSwipeRecognizer()
        XCTAssertEqual(recognizer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        let panel = UIView(), inside = UIScrollView(), outside = UIScrollView()
        panel.addSubview(inside)
        panel.addGestureRecognizer(recognizer)
        XCTAssertTrue(recognizer.shouldBeRequiredToFail(by: inside.panGestureRecognizer))
        XCTAssertFalse(recognizer.shouldBeRequiredToFail(by: outside.panGestureRecognizer), "The worksheet's canvas never waits for it")
    }

    // MARK: State

    private func freshDefaults() -> UserDefaults {
        let name = "CopySlideOverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testItStartsClosedEveryTimeAndKeepsOnlyItsSideAndWidth() {
        let defaults = freshDefaults()
        let first = SlideOverState(defaults: defaults)
        XCTAssertFalse(first.isOpen, "Closed until its tab is tapped")
        XCTAssertEqual(first.side, .trailing, "On the right by default, like Slide Over")
        first.apply(.dock(.leading))
        first.setWidth(450)
        XCTAssertTrue(first.isOpen)

        let relaunched = SlideOverState(defaults: defaults)
        XCTAssertFalse(relaunched.isOpen, "Left open, it still opens closed on the next worksheet")
        XCTAssertEqual(relaunched.side, .leading)
        XCTAssertEqual(relaunched.width, 450)
    }

    func testClosingAndSlidingOffAnEdgeKeepTheTabOnThatEdge() {
        let state = SlideOverState(defaults: freshDefaults())
        state.open()
        state.close()
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.side, .trailing)
        state.apply(.hide(.leading))
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.side, .leading)
    }

    // MARK: Content and privacy

    private func record(_ role: DocumentRole) throws -> DocumentRecord {
        let key = try PaperKey(rawValue: "synthetic-slide-over")
        let publication = try Publication(subject: "Synthetic Subject", classTag: nil, paperKey: key, role: role,
                                          title: "Synthetic \(role.rawValue)")
        let data = Data("synthetic".utf8)
        let entry = try ManifestEntry(source: SourcePath(classFolder: "Synthetic Subject", relativePath: "\(role.rawValue).pdf"),
                                      sha256: ContentHash.digest(data), size: Int64(data.count), modifiedAt: Date(),
                                      publication: publication)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: Date(timeIntervalSince1970: 0))
    }

    func testATeacherCopyShowsNoPagesWhilePrivateContentIsHiddenAndAStudentCopyAlwaysDoes() throws {
        let teacher = try record(.teacher), student = try record(.student)
        for display in [false, true] {
            for external in [0, 1] {
                for active in [false, true] {
                    let policy = PresentationPolicy(otherDisplayAttached: display, externalSceneCount: external, mainSceneActive: active)
                    let content = CopySlideOverContent.resolve(teacher, policy: policy, mainSceneActive: active)
                    if policy.hidePrivateContent {
                        XCTAssertEqual(content, .hidden(active ? .capture : .inactive), "\(policy)")
                    } else {
                        XCTAssertEqual(content, .pages, "\(policy)")
                    }
                    XCTAssertEqual(CopySlideOverContent.resolve(student, policy: policy, mainSceneActive: active), .pages)
                }
            }
        }
    }

    func testItsWordsNameTheCopyItHolds() {
        XCTAssertEqual(CopySlideOverText.tabLabel(.teacher), "Show Teacher copy")
        XCTAssertEqual(CopySlideOverText.tabLabel(.student), "Show Student copy")
        XCTAssertEqual(CopySlideOverText.closeLabel(.student), "Hide Student copy")
        XCTAssertEqual(CopySwapLabel.title(.student), "Student")
        XCTAssertEqual(CopySwapLabel.title(.teacher), "Teacher")
    }
}
